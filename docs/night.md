# Captura noturna apoiada (0.4.0 / 0.5.0)

A 0.3.3 sempre usava o modo Foto: oito RAWs com obturador/ISO derivados do preview. No ensaio noturno recebido, o DNG tinha ISO640 e1/43s, aproximadamente0,19s somados sob a trava de exposicao. Processar por13s nao acrescentou luz capturada. Os modos Noite/Longa existentes na configuracao nao estavam ligados ao app.

## Modos e politica

| Modo | Captura | Fusao | Uso |
|---|---|---|---|
| Foto | 8frames; politica AE anterior, -0,5EV | Robusta por frequencia | Uso na mao de dia |
| Noite | 16frames; troca ISO por obturador longo, -0,5EV | Robusta por frequencia | Tripe e cena parada |
| Longa | 16frames; troca ISO por obturador longo, EV0 | Media alinhada de todos os frames | Tripe; movimento produz rastros |

Noite/Longa preservam o produto obturador*ISO solicitado sempre que os limites do dispositivo permitem, priorizando ISO minimo e limitando o obturador ao menor entre0,5s e o maximo do formato. A exposicao de cada frame nao e multiplicada indiscriminadamente. Em condicao equivalente ao ensaio, Noite calcula aproximadamente0,5s/ISO30: ate8s somados em16frames. Valores do plano precisam ser conferidos no EXIF de cada ensaio. A media de Longa normaliza a soma para nao multiplicar o pedestal preto nem saturar o buffer pelo numero de frames. Intervalos entre fotos podem produzir rastros segmentados.

Ha dois segundos para estabilizar o tripe apos tocar. AE/AF/WB precisam convergir antes da trava; se nao convergirem em tres segundos, a captura informa o problema. O timeout acompanha o obturador e a quantidade de fotos. Ao terminar ou abortar, modos e limites de frame duration do preview sao restaurados.

## Como testar

Selecionar **Noite**, apoiar o aparelho e acionar o obturador principal em uma cena parada. Para o efeito de rastros, selecionar **Longa**. Esses modos exigem tripe; nao ha deteccao automatica de estabilidade nem politica noturna para uso na mao. Guardar RAWs adiciona cerca de420MB por captura e deve ficar ligado nos ensaios. O manifest registra modo, plano, merge e exposicao/ISO EXIF por frame quando disponiveis; a soma medida e emitida somente se todas as duracoes estiverem presentes.

Conferir ISO/tempo efetivos, alinhamento, ruido/detalhe, realces, cores, tempo de captura/processamento, termica e pico de memoria. Os16RAWs retidos ocupam390MB antes dos demais buffers. Testes numericos e build nao aprovam qualidade noturna; o bracket0.5.0 e o acabamento0.6.0 ainda precisam de teste fisico.

## Realces e acabamento (0.4.1 / 0.5.0)

A 0.4.1 permite ao mapa local reduzir iluminacao forte, alem de elevar sombras, e usa shoulder racional para manter mais degraus claros no JPEG8bit. Isso nao recupera informacao ja saturada no RAW. Um ensaio fisico 0.4.0 confirmou 16 exposicoes de0,5s/ISO32, oito segundos somados; o primeiro RAW tinha aproximadamente0,93% de amostras no branco do sensor. O usuario relatou melhora noturna e realces ainda excessivos.

A 0.5.0 mede realces no primeiro RAW de Noite: se pelo menos0,05% das amostras esparsas estiverem perto do branco, indices3/7/11/15 passam a usar exposicao ate16vezes mais curta, ao mesmo ISO. Sao12longas+4curtas; com0,5s e1/32s, a integracao planejada cai de8 para6,125s. Sem realces relevantes, mantem16longas. Foto e Longa conservam suas politicas.

Cada grupo e fundido separadamente, e o produto tempo*ISO EXIF precisa confirmar os grupos com tolerancia5% e razao2..32. A combinacao recupera radiancia dos claros em UInt32 antes do demosaic; sombras ficam com o grupo longo. Peso compartilhado pela celula Bayer e teste de discordancia limitam a combinacao de movimento, sem substituir registro local/subpixel. Fontes que saturam ate a exposicao curta continuam sem informacao recuperavel. Ha testes numericos de radiancia acima65535, sombras, movimento, cobertura e metadados invalidos; bracket efetivo, ghosting e qualidade fisica desta politica ainda precisam ser medidos no SE.

A 0.6.0 acrescenta [referencia de preview](preview.md) ao acabamento. A saida continua JPEG SDR, sem gain map de exibicao HDR.

## Referencias

- [Apple: exposicao customizada](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)?changes=_2): limites do dispositivo e efeito sobre duracoes do preview.
- [Google, fotografia em pouca luz, 2019](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/): escolha conjunta de obturador/frames e tratamento especializado de ruido/movimento. A politica manual de tripe do BurstLab nao reproduz o motion metering ou AWB aprendido desse sistema.
