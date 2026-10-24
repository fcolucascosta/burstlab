# Preview como referencia (0.6.0)

O retorno do usuario define o objetivo: preservar a aparencia observada no preview, com melhor detalhe e menos ruido no JPEG. Um material preto deve permanecer preto; o brilho medio da cena nao permite distinguir tinta preta de uma sombra. O medidor anterior procurava uma media logaritmica de 0,18 e o mapa local podia elevar ainda mais os escuros, destacando ruido.

## Implementacao

Uma saida de video auxiliar acompanha a mesma camera do AVCaptureVideoPreviewLayer. Usa buffers de preview configurados automaticamente pelo AVFoundation, descarta frames atrasados e converte uma amostra para sRGB SDR de no maximo 96x96. O app conserva apenas RGBA8 e luminancias, sem reter o buffer de video. Amostra no maximo quatro vezes por segundo e suspende essa analise durante captura/processamento. O proxy deve ter chegado ha no maximo 0,75s ao tocar o obturador; o timestamp de video tambem precisa ser recente.

O acabamento compara a luminancia do RAW fundido, ja passada pelo mapa de tom, com o proxy. Recorta o campo central comum quando os aspectos diferem e compara uma grade de 18 linhas. A correlacao espacial em log deve atingir 0,75 antes de usar quantis para ajustar contraste. Duas imagens quase uniformes podem orientar somente um ganho de brilho; uma referencia uniforme para uma cena estruturada e rejeitada.

A curva global e monotona, com nove quantis, interpolacao logaritmica e limites de ganho de 1/16 a 4. Zero permanece zero. Os tons medios recebem ate +0,15EV em relacao ao proxy; o ganho extra diminui em direcao ao branco. Ha compressao de gamut preservando a direcao cromatica. Nenhum pixel de detalhe do video entra no JPEG: merge, demosaic e render continuam em resolucao completa. Sem referencia recente/valida, conserva-se o acabamento anterior. Cor DNG, filtro cromatico e look Oklab permanecem iguais.

## Evidencia e limites

O replay local do notebook usa IMG_0987.JPG e a foto padrao IMG_0988.HEIC como referencia aproximada. O notebook ficou mais proximo da referencia sem transformar o preto em cinza claro. Isso avalia a direcao da curva, nao comprova correspondencia ao preview: o app anterior nao o guardava, o video do notebook mudou e as exposicoes nao sao iguais. A comparacao noturna tambem e exploratoria. Fotos, RAWs, replays e metricas ficam somente em reports/preview-20261023/.

Testes verificam materiais escuros, tons medios, monotonicidade, preservacao de modulacao, neutros/gamut, cenas incompatíveis, quantis repetidos e recorte de aspecto. O CI exercita o sampler de producao com um buffer de quadrantes conhecido para conferir orientacao, canais, downsample e luminancia sRGB. Ainda e necessario medir a captura no SE: disponibilidade/conversao do proxy, correspondencia com o preview visto, ruido/detalhe e custo de memoria/termica. A amostra e um proxy de video SDR, nao uma captura da tela; HDR de exibicao, crop da interface e processamento do sistema podem diferir.

Esta revisao nao adiciona blur de luma nem sharpening. Reduzir elevacao indevida dos pretos pode reduzir a visibilidade do ruido, mas nao demonstra reducao do ruido do sensor/merge. O ensaio do notebook usava Foto, oito frames de aproximadamente 1/33s, ISO640. O ensaio noturno mais recente tem 16 frames de 0,5s, ISO160. Regioes RAW apresentam discrepancias diferentes em relacao ao NoiseProfile, e movimento/flicker podem contaminar a estimativa: nao ha justificativa para aumentar indiscriminadamente o denoise ou aceitar mais movimento no merge.

## Readback e reversao

Com Guardar RAWs para comparacao, o manifest schema3 inclui preview_reference (dimensoes/luminancias) e preview.rgba8 sRGB sem rotacao. processing.json inclui preview_available, preview_tone_used, preview_contrast_curve_used, preview_scene_correlation e preview_median_correction_ev. Uma correlacao zero com preview_tone_used=1 e preview_contrast_curve_used=0 indica ganho para cena uniforme, nao uma correlacao medida perfeita.

Comparar a mesma cena com corpo preto, tela e parede, em Foto e Noite apoiado. Conferir a amostra armazenada antes de avaliar a curva. Arquivos antigos continuam sem proxy e nao permitem reconstruir o preview original. Para reverter somente este experimento, reinstalar o IPA 0.5.0 preservado em build/dist; 0.4.1 e a referencia fisica recebida, mas tambem remove o bracket de realces.

Referencias de API: [dimensoes automaticas de buffers de video](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/automaticallyconfiguresoutputbufferdimensions) e [arquitetura de sessao de captura](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session).
