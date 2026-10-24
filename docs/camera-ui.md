# Camera e foco por toque (0.7.0)

A interface separa controles da imagem: viewfinder4:3, grade opcional, modos Foto/Noite/Longa, obturador central, referencia pelo sistema e miniatura da ultima foto feita nesta sessao. A revisao abre o JPEG em memoria; diagnosticos e versao ficam em Ajustes. O modo Longa continua explicando rastros e os modos apoiados pedem tripe.

Antes desta revisao, tocar no preview nao acionava foco. Agora o ponto e convertido pelo AVCaptureVideoPreviewLayer para coordenadas do sensor, respeitando rotacao e crop. Sob lockForConfiguration, o controlador define pontos de foco/exposicao e solicita AF/AE continuos quando suportados. O quadrado amarelo marca o pedido, e o retorno informa ponto definido ou demora para estabilizar; nao e medicao de nitidez. A captura espera o foco estabilizar antes de trava-lo, inclusive em Foto. Depois de um toque, tambem espera a exposicao e descarta a referencia anterior de preview; congela uma amostra recente apos estabilizar.

Toques sao bloqueados durante captura/processamento. O sistema nao oferece bloqueio AE/AF por toque longo nem zoom manual nesta revisao. Teste no SE com texto perto/longe e alvo fora do centro; conferir a posicao do quadrado, foco real, exposicao e o JPEG. O CI executa o app iPhone em um simulador SE2022 e exporta screenshot para revisar layout; esse teste nao valida lente, AF/AE ou qualidade fotografica.

API: [conversao do ponto do preview](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/capturedevicepointconverted(fromlayerpoint:)) e [ponto de exposicao](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposurepointofinterest).
