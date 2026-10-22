# Captura noturna apoiada (0.4.0)

A 0.3.3 sempre usava o modo Foto: oito RAWs com obturador/ISO derivados do preview. No ensaio noturno recebido, o DNG tinha ISO640 e1/43s, aproximadamente0,19s somados sob a trava de exposicao. Processar por13s nao acrescentou luz capturada. Os modos Noite/Longa existentes na configuracao nao estavam ligados ao app.

## Modos e politica

| Modo | Captura | Fusao | Uso |
|---|---|---|---|
| Foto | 8frames; politica AE anterior, -0,5EV | Robusta por frequencia | Uso na mao de dia |
| Noite | 16frames; troca ISO por obturador longo, -0,5EV | Robusta por frequencia | Tripe e cena parada |
| Longa | 16frames; troca ISO por obturador longo, EV0 | Media alinhada de todos os frames | Tripe; movimento produz rastros |

Noite/Longa preservam o produto obturador*ISO solicitado sempre que os limites do dispositivo permitem, priorizando ISO minimo e limitando o obturador ao menor entre0,5s e o maximo do formato. A exposicao de cada frame nao e multiplicada indiscriminadamente. Em condicao equivalente ao ensaio, Noite calcula aproximadamente0,5s/ISO30: ate8s somados em16frames. E um plano, nao uma captura validada. A media de Longa normaliza a soma para nao multiplicar o pedestal preto nem saturar o buffer pelo numero de frames. Intervalos entre fotos podem produzir rastros segmentados.

Ha dois segundos para estabilizar o tripe apos tocar. AE/AF/WB precisam convergir antes da trava; se nao convergirem em tres segundos, a captura informa o problema. O timeout acompanha o obturador e a quantidade de fotos. Ao terminar ou abortar, modos e limites de frame duration do preview sao restaurados.

## Como testar

Selecionar **Noite**, apoiar o aparelho e acionar o obturador principal em uma cena parada. Para o efeito de rastros, selecionar **Longa**. Esses modos exigem tripe; nao ha deteccao automatica de estabilidade nem politica noturna para uso na mao. Guardar RAWs adiciona cerca de420MB por captura e deve ficar ligado nos ensaios. O manifest registra modo, plano, merge e exposicao/ISO EXIF por frame quando disponiveis; a soma medida e emitida somente se todas as duracoes estiverem presentes.

Conferir ISO/tempo efetivos, alinhamento, ruido/detalhe, realces, cores, tempo de captura/processamento, termica e pico de memoria. Os16RAWs retidos ocupam390MB antes dos demais buffers. Testes numericos e build nao aprovam qualidade noturna; falta teste fisico desta revisao.

## Referencias

- [Apple: exposicao customizada](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)?changes=_2): limites do dispositivo e efeito sobre duracoes do preview.
- [Google, fotografia em pouca luz, 2019](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/): escolha conjunta de obturador/frames e tratamento especializado de ruido/movimento. A politica manual de tripe do BurstLab nao reproduz o motion metering ou AWB aprendido desse sistema.
