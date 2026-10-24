# Processamento Apple e modelos pequenos

O estudo deve comparar etapas executaveis com os mesmos dados: RAW, alinhamento/fusao, demosaic/denoise, cor, tom e nitidez. A documentacao do Indigo descreve um modelo que orienta ajustes de acabamento a partir do RAW fundido. Ela nao fornece os pesos desse modelo nem revela o pipeline privado do app Camera da Apple.

Uma alternativa publica concreta e CIRAWFilter. A Apple documenta que RAW9 no iOS27 usa CoreML em tiles para demosaic e denoise conjuntos, com execucao no dispositivo. Disponibilidade para um DNG e escolha do decoder precisam ser consultadas; nao se presume que a inicializacao use9. A API de revelacao RAW nao expoe o fluxo completo SmartHDR/DeepFusion da Camera.

## Comparacao implementada na0.7.0

Em Ajustes > Laboratorio > Comparar ultimo RAW com processamento Apple, o app abre o reference.dng do ultimo ensaio completo guardado. Consulta supportedDecoderVersions, seleciona apenas o primeiro valor devolvido (lista documentada em ordem cronologica inversa) e registra o decoder inicial/efetivo. Isso permite testar um decoder novo do iOS sem depender de uma constante ausente no SDK de build26.5. Nenhum valor arbitrario e forcado.

O experimento roda somente sob demanda, com captura/processamento ociosos. Usa meia dimensao (aproximadamente3MP) e cacheIntermediates=false; mantem ajustes nativos de exposicao, ruido e nitidez e exporta SDR sRGB. Guarda apple-raw-reference.jpg/json no mesmo ensaio e permite abrir a imagem em Ajustes. Registra decoders, parametros, dimensoes e tempo. Nao modifica o DNG nem a foto final, nao exige novos modelos/credenciais e nao envia arquivos.

E um RAW individual. Nao incorpora o merge/HDR do BurstLab. Para comparar ruido/detalhe, igualar resolucao, brilho e quantidade de entradas; nao atribuir diferencas ao modelo quando vierem de resize ou numero de frames. Decoder9 disponivel nao mede uso efetivo do Neural Engine, memoria ou ganho de qualidade. O SE precisa fornecer esses primeiros resultados antes de promover esse revelador ao pipeline principal.

## Proxima decisao baseada em dados

Primeiro conferir captura sem duplicatas e a ordem cor/tom corrigidas. Depois comparar o revelador Apple com a revelacao do mesmo RAW no BurstLab, incluindo tecido fino, iluminantes artificiais e sombras; medir textura, ruido, cor, latencia e memoria. Se um modelo proprio for necessario, estudar denoise RAW compacto ou previsao de parametros de acabamento. Quantizacao/CoreML precisam de dados representativos e verificacao no A15; uma rede pequena so pelo tamanho nao garante melhor fotografia.

Fontes primarias: [Apple, Core Image RAW9/WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/), [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter), [lista de decoders suportados](https://developer.apple.com/documentation/coreimage/cirawfilter/supporteddecoderversions), [Indigo, Adobe Research](https://research.adobe.com/articles/indigo/indigo.html) e [Burst Denoising with Kernel Prediction Networks](https://openaccess.thecvf.com/content_cvpr_2018/papers/Mildenhall_Burst_Denoising_With_CVPR_2018_paper.pdf).
