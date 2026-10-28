import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart' hide Router; // Oculta o Router do Flutter para evitar conflitos
import 'package:camera/camera.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router; // Prefixo para evitar conflito
import 'package:bonsoir/bonsoir.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  
  Uint8List? _latestFrame;
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
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _cameraController!.initialize();
      setState(() {});
    } catch (e) {
      debugPrint("Erro ao iniciar câmara: $e");
    }
  }

  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage image) {
      final now = DateTime.now();
      final interval = 1000 ~/ _targetFps;
      
      if (now.difference(_lastFrameTime).inMilliseconds >= interval) {
        _lastFrameTime = now;
        
        // CORREÇÃO: Aceder à propriedade .bytes de dentro do primeiro plano (.first) da lista
        if (image.planes.isNotEmpty && image.planes.first.bytes.isNotEmpty) {
          setState(() {
            _latestFrame = image.planes.first.bytes;
          });
        }
      }
    });
  }

  Future<void> _startServer() async {
    final router = shelf_router.Router(); // Correção do Conflito 1

    router.get('/stream', (shelf.Request request) {
      final controller = StreamController<List<int>>();
      
      Timer.periodic(Duration(milliseconds: 1000 ~/ _targetFps), (timer) {
        if (!_isStreaming || _latestFrame == null) {
          timer.cancel();
          controller.close();
          return;
        }

        try {
          controller.add(ImageHttpFormatter.formatFrame(_latestFrame!));
        } catch (e) {
          timer.cancel();
          controller.close();
        }
      });

      return shelf.Response.ok(
        controller.stream,
        headers: {
          'Content-Type': 'multipart/x-mixed-replace; boundary=--frame',
          'Cache-Control': 'no-cache, private',
          'Pragma': 'no-cache',
        },
      );
    });

    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String localIp = "127.0.0.1";
    if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
      localIp = interfaces.first.addresses.first.address;
    }

    _httpServer = await shelf_io.serve(router, InternetAddress.anyIPv4, 8080);
    
    // Correção do Conflito 2 (Nova sintaxe do Bonsoir v7)
    BonsoirService service = BonsoirService(
      name: 'Camera_Impressora_3D',
      type: '_3dprintmonitor._tcp',
      port: 8080,
    );
    
    _bonsoirBroadcast = BonsoirBroadcast(service: service);
    await _bonsoirBroadcast!.start(); // A v7 inicializa diretamente pelo start assíncrono

    WakelockPlus.enable();

    setState(() {
      _isStreaming = true;
      _serverIp = "http://$localIp:8080/stream";
    });

    _startImageStream();
  }

  Future<void> _stopServer() async {
    await _cameraController?.stopImageStream();
    await _bonsoirBroadcast?.stop();
    await _httpServer?.close(force: true);
    WakelockPlus.disable();

    setState(() {
      _isStreaming = false;
      _isEconomicMode = false;
      _serverIp = "Desconectado";
      _latestFrame = null;
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _httpServer?.close();
    _bonsoirBroadcast?.stop();
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
          Container(
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
                      items: [1, 5, 10, 15].map((fps) {
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
          ),
        ],
      ),
    );
  }
}

class ImageHttpFormatter {
  static List<int> formatFrame(Uint8List frameBytes) {
    final List<int> chunks = [];
    chunks.addAll('--frame\r\n'.codeUnits);
    chunks.addAll('Content-Type: image/jpeg\r\n'.codeUnits);
    chunks.addAll('Content-Length: ${frameBytes.length}\r\n\r\n'.codeUnits);
    chunks.addAll(frameBytes);
    chunks.addAll('\r\n'.codeUnits);
    return chunks;
  }
}
