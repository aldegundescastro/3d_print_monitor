# 3D Print Monitor

Aplicativo Flutter para transformar um smartphone em uma webcam sem fio para monitorar impressoras 3D em tempo real. O app inicia um servidor HTTP no próprio celular, servindo o vídeo da câmera em formato MJPEG através de um stream multipart, acessível diretamente pelo navegador do PC na mesma rede Wi-Fi.

## Como funciona

- **Servidor local no celular**: Ao iniciar o servidor, o aplicativo cria um servidor HTTP (`shelf`) na porta `8080`, expondo a transmissão da câmera.
- **Captura via `takePicture()`**: Em vez de usar streams de imagem diretos, o app captura quadros JPEG válidos com `CameraController.takePicture()` em intervalo definido pelo FPS escolhido.
- **Transmissão MJPEG**: Os quadros são enviados no formato `multipart/x-mixed-replace` com `boundary=frame`, permitindo que navegadores exibam o vídeo ao vivo com uma tag `<img>` ou diretamente na rota `/stream`.
- **Descoberta na rede**: Utiliza `bonsoir` para anunciar o serviço na rede local via mDNS (`_3dprintmonitor._tcp`).
- **Economia de energia**: Com `wakelock_plus`, mantém a tela ligada enquanto o servidor estiver ativo.
- **Interface otimizada**: Durante a transmissão, o preview da câmera é ocultado no celular para evitar conflitos entre `CameraPreview` e a captura, evitando o travamento da imagem.

## Funcionalidades

- Transmissão ao vivo em MJPEG
- Seleção da taxa de quadros (FPS): 1, 5, 10, 15 ou 30
- Modo econômico (oculta informações e tela preta ao tocar duas vezes para sair)
- Exibição do endereço IP local para acesso pelo navegador
- Página HTML embutida na rota `/` para visualização rápida
- Suporte a acesso direto via `/stream`

## Como utilizar

### Requisitos
- Smartphone Android ou iOS com câmera
- Computador na mesma rede Wi-Fi que o smartphone
- Navegador moderno (Chrome, Edge, Firefox, Opera)

### Passo a passo

1. **Instalar e abrir o app**: Abra o `3D Print Monitor` no seu smartphone.
2. **Aguardar inicialização da câmera**: Aguarde até que a pré-visualização ou a tela principal seja carregada.
3. **Configurar FPS (opcional)**: Escolha a taxa de quadros desejada antes de iniciar o servidor. Quanto maior o FPS, maior o uso de CPU/bateria e largura de banda.
4. **Iniciar servidor**: Toque em "Iniciar Servidor". O app exibirá o endereço no formato `http://[IP]:8080/stream` e a mensagem "TRANSMISSÃO ATIVA".
5. **Visualizar no PC**: No navegador do computador, acesse:
   - `http://[IP_DO_CELULAR]:8080/` - Página HTML com a imagem já embutida (recomendado para testes)
   - `http://[IP_DO_CELULAR]:8080/stream` - Stream direto MJPEG
6. **Parar transmissão**: No celular, toque em "Parar Servidor". A pré-visualização da câmera voltará a ser exibida.

## Dicas e observações

- **Mesma rede**: O PC e o celular precisam estar conectados à mesma rede Wi-Fi. Não funciona corretamente em redes isoladas (alguns hotspots ou redes corporativas com isolamento de clientes).
- **Porta 8080**: Certifique-se de que a porta 8080 não está bloqueada pelo firewall do roteador/rede.
- **Bateria**: Com wakelock ativado, o celular ficará com a tela ligada. Use o modo econômico se desejar economizar um pouco de energia visual.
- **Latência**: Por ser MJPEG via HTTP na rede local, a latência é baixa o suficiente para monitorar impressões 3D, mas não é tão baixa quanto WebRTC P2P.
- **Se o IP estiver incorreto**: Em alguns casos com VPN ativa, o IP exibido pode estar errado. Desative VPNs temporariamente caso o navegador não consiga conectar.

## Tecnologias utilizadas

- [Flutter](https://flutter.dev/) - Framework multiplataforma
- [camera](https://pub.dev/packages/camera) - Acesso à câmera
- [shelf](https://pub.dev/packages/shelf) & [shelf_router](https://pub.dev/packages/shelf_router) - Servidor HTTP local
- [bonsoir](https://pub.dev/packages/bonsoir) - Descoberta mDNS na rede local
- [wakelock_plus](https://pub.dev/packages/wakelock_plus) - Manter tela ligada