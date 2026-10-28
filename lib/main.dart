import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart' hide Router;
import 'package:camera/camera.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:bonsoir/bonsoir.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:image/image.dart' as img;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '3D Print Monitor',
      theme: ThemeData.dark(),
      home: MonitorScreen(cameras: cameras),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const MonitorScreen({super.key, required this.cameras});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  CameraController? _cameraController;
  HttpServer? _httpServer;
  BonsoirBroadcast? _bonsoirBroadcast;
  
  // Utilização de uma referência mutável simples para evitar renderizações excessivas do setState
  Uint8List? _rawFrameBuffer;
  bool _isStreaming = false;
  bool _isEconomicMode = false;
  int _targetFps = 10;
  String _serverIp = "Desconectado";
  DateTime _lastFrameTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;
    
    _cameraController = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium, // Melhor equilíbrio entre nitidez e fluidez
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      setState(() {});
    } catch (e) {
      debugPrint("Erro ao iniciar câmara: $e");
    }
  }

  Uint8List? _yuv420ToJpeg(CameraImage image) {
    try {
      final width = image.width;
      final height = image.height;
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      final imgBuffer = img.Image(width: width, height: height);

      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int yIndex = y * yPlane.bytesPerRow + x;
          final int uvIndex = uvRowStride * (y ~/ 2) + uvPixelStride * (x ~/ 2);

          final int yp = yPlane.bytes[yIndex];
          // Em muitos dispositivos Android os planos U/V estão trocados
          final int up = vPlane.bytes[uvIndex];
          final int vp = uPlane.bytes[uvIndex];

          // Conversão YUV (BT.601)
          int r = (yp + vp * 1436 / 1024 - 179).round();
          int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round();
          int b = (yp + up * 1814 / 1024 - 227).round();

          r = r.clamp(0, 255);
          g = g.clamp(0, 255);
          b = b.clamp(0, 255);

          imgBuffer.setPixelRgb(x, y, r, g, b);
        }
      }

      // Corrige rotação para visualização correta no navegador
      img.Image rotated = img.copyRotate(imgBuffer, angle: 90);

      return Uint8List.fromList(img.encodeJpg(rotated, quality: 55));
    } catch (e) {
      debugPrint('Erro conversão YUV->JPEG: $e');
      return null;
    }
  }

  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage image) {
      final now = DateTime.now();
      final interval = 1000 ~/ _targetFps;

      if (now.difference(_lastFrameTime).inMilliseconds >= interval) {
        _lastFrameTime = now;
        final jpeg = _yuv420ToJpeg(image);
        if (jpeg != null && jpeg.isNotEmpty) {
          _rawFrameBuffer = jpeg;
        }
      }
    });
  }

  Future<void> _startServer() async {
    final router = shelf_router.Router();

    router.get('/', (shelf.Request request) {
      final html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>3D Print Monitor</title>
  <style>
    body { background: #000; color: #fff; text-align: center; font-family: sans-serif; margin: 0; padding: 16px; }
    img { max-width: 100%; height: auto; border-radius: 8px; }
  </style>
</head>
<body>
  <h2>3D Print Monitor</h2>
  <img src="/stream" />
</body>
</html>
''';
      return shelf.Response.ok(
        html,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );
    });

    router.get('/stream', (shelf.Request request) {
      final controller = StreamController<List<int>>();
      Timer? timer;
      bool closed = false;

      void cleanup() {
        if (closed) return;
        closed = true;
        timer?.cancel();
        if (!controller.isClosed) {
          controller.close();
        }
      }

      timer = Timer.periodic(Duration(milliseconds: 1000 ~/ _targetFps), (t) {
        if (!_isStreaming || closed) {
          cleanup();
          return;
        }

        final frame = _rawFrameBuffer;
        if (frame != null && frame.isNotEmpty) {
          try {
            controller.add(ImageHttpFormatter.formatFrame(frame));
          } catch (e) {
            cleanup();
          }
        }
      });

      controller.onCancel = cleanup;

      return shelf.Response.ok(
        controller.stream,
        headers: {
          'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Connection': 'keep-alive',
          'Pragma': 'no-cache',
          'Access-Control-Allow-Origin': '*',
        },
      );
    });

    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String localIp = "127.0.0.1";
    if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
      localIp = interfaces.first.addresses.first.address;
    }

    _httpServer = await shelf_io.serve(router, InternetAddress.anyIPv4, 8080);
    
    BonsoirService service = BonsoirService(
      name: 'Camera_Impressora_3D',
      type: '_3dprintmonitor._tcp',
      port: 8080,
    );
    
    _bonsoirBroadcast = BonsoirBroadcast(service: service);
    await _bonsoirBroadcast!.start();

    WakelockPlus.enable();

    setState(() {
      _isStreaming = true;
      _serverIp = "http://$localIp:8080/stream";
    });

    _startImageStream();
  }

  Future<void> _stopServer() async {
    if (_cameraController?.value.isStreamingImages ?? false) {
      await _cameraController?.stopImageStream();
    }
    await _bonsoirBroadcast?.stop();
    await _httpServer?.close(force: true);
    WakelockPlus.disable();

    setState(() {
      _isStreaming = false;
      _isEconomicMode = false;
      _serverIp = "Desconectado";
      _rawFrameBuffer = null;
    });
  }

  @override
  void dispose() {
    _stopServer();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_isEconomicMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onDoubleTap: () {
            setState(() {
              _isEconomicMode = false;
            });
          },
          child: const Center(
            child: Text(
              'MODO ECONÓMICO ATIVO\n(Toque duas vezes para sair)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white30, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      );
    }

    Widget controlPanel = Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Text(
            _isStreaming ? "🔴 TRANSMITINDO" : "⚪ DISPONÍVEL",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: _isStreaming ? Colors.red : Colors.green,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            _serverIp,
            style: const TextStyle(fontSize: 16, color: Colors.blue),
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Taxa de Frames (FPS):"),
              DropdownButton<int>(
                value: _targetFps,
                // CORREÇÃO: Declarar explicitamente o array antes do método .map
                items: [1, 5, 10, 15, 30].map((fps) {
                  return DropdownMenuItem(value: fps, child: Text("$fps FPS"));
                }).toList(),
                onChanged: _isStreaming ? null : (value) {
                  if (value != null) setState(() => _targetFps = value);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isStreaming ? Colors.red : Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _isStreaming ? _stopServer : _startServer,
                  icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
                  label: Text(_isStreaming ? "Parar Servidor" : "Iniciar Servidor"),
                ),
              ),
              if (_isStreaming) ...[
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => setState(() => _isEconomicMode = true),
                  child: const Icon(Icons.wb_incandescent_outlined),
                ),
              ]
            ],
          ),
        ],
      ),
    );

    if (_isStreaming) {
      return Scaffold(
        appBar: AppBar(title: const Text('💡 3D Print Camera Server')),
        body: Column(
          children: [
            const Expanded(
              child: Center(
                child: Text(
                  'TRANSMISSÃO ATIVA\nVisualize no browser',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),
              ),
            ),
            controlPanel,
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('💡 3D Print Camera Server')),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CameraPreview(_cameraController!),
              ),
            ),
          ),
          controlPanel,
        ],
      ),
    );
  }
}

// FORMATADOR ESTRITO: Insere as quebras de linha corretas exigidas pelos navegadores
class ImageHttpFormatter {
  static List<int> formatFrame(Uint8List frameBytes) {
    final List<int> chunks = [];
    chunks.addAll('--frame\r\n'.codeUnits);
    chunks.addAll('Content-Type: image/jpeg\r\n'.codeUnits);
    chunks.addAll('Content-Length: ${frameBytes.length}\r\n\r\n'.codeUnits);
    chunks.addAll(frameBytes);
    chunks.addAll('\r\n'.codeUnits); // Quebra de linha final obrigatória pós-binário
    return chunks;
  }
}
