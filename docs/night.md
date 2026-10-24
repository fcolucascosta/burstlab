# Captura noturna apoiada (0.7.0)

## Errata: callbacks nao sao exposicoes independentes

A auditoria dos arquivos revelou2RAWs distintos em16callbacks nos ensaios038F22AF(0.4.0),815918B9(0.4.1),94F7E771/34434B9B(0.6.0). Grupos de6-10arquivos tinham SHA256 identico. Um controle Foto0.4.1 tinha8arquivos distintos. Portanto, a soma de16EXIFs de0,5s nao comprovava8s de integracao independente; as estimativas de ruido que tratavam esses16arquivos como amostras independentes ficam invalidadas. A igualdade byte a byte e evidencia de repeticao, nao uma estimativa estatistica.

A0.7.0 limita a cadencia dos pedidos de Noite/Longa pela duracao anterior+50ms, em vez de seguir a velocidade do callback. Antes de aceitar qualquer RAW, verifica SHA256 dos pixels sem padding e timestamp de foto crescente. Repeticoes nao avancam o contador; ha ate3tentativas por posicao e cancelamento explicito se persistirem, alem do timeout global. A politica Foto mantem pedidos rapidos, com a mesma verificacao de identidade. Hashes distintos ainda nao demonstram ruido temporal independente ou melhor SNR; o proximo ensaio precisa conferir os16hashes e espacamento dos timestamps no SE.

Manifest schema4 registra pixel_sha256 por arquivo, unique_pixel_frames, repeated_or_stale_raw_rejections, photo_timestamp_seconds, accepted_photo_timestamp_span_seconds e unique_frame_exposure_sum_seconds. O ultimo campo soma EXIF somente de imagens aceitas; nao mede exposicao continua nem inclui intervalos. O nome anterior measured_integration_seconds foi removido para evitar essa interpretacao.

O primeiro readback0.7.0(A2CD834E-0900-41D6-9A14-3B9053489FD8) confirmou16arquivos distintos, com hashes recalculados no computador iguais aos do manifest e0rejeicoes. EXIF0,5s/ISO160 em todos; timestamps espacados de0,50605a1,01210s, span8,60281s e soma nominal8s. Todos deslocamentos globais0; processamento22,2933s, excluindo exportacao e fototeca. O usuario relatou melhora acentuada. Isso confirma a correcao das duplicatas neste ensaio; nao mede SNR, termica/memoria ou independencia estatistica do ruido. Nao havia bracket de realces ativo nesta cena.

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

A 0.4.1 permite ao mapa local reduzir iluminacao forte, alem de elevar sombras, e usa shoulder racional para manter mais degraus claros no JPEG8bit. Isso nao recupera informacao ja saturada no RAW. O ensaio0.4.0 tinha16callbacks com EXIF0,5s/ISO32, mas apenas2RAWs distintos conforme a auditoria acima; nao comprovava8s de integracao independente. O primeiro RAW tinha aproximadamente0,93% de amostras no branco do sensor. O usuario relatou melhora noturna e realces ainda excessivos.

A 0.5.0 mede realces no primeiro RAW de Noite: se pelo menos0,05% das amostras esparsas estiverem perto do branco, indices3/7/11/15 passam a usar exposicao ate16vezes mais curta, ao mesmo ISO. Sao12longas+4curtas; com0,5s e1/32s, a integracao planejada cai de8 para6,125s. Sem realces relevantes, mantem16longas. Foto e Longa conservam suas politicas.

Cada grupo e fundido separadamente, e o produto tempo*ISO EXIF precisa confirmar os grupos com tolerancia5% e razao2..32. A combinacao recupera radiancia dos claros em UInt32 antes do demosaic; sombras ficam com o grupo longo. Peso compartilhado pela celula Bayer e teste de discordancia limitam a combinacao de movimento, sem substituir registro local/subpixel. Fontes que saturam ate a exposicao curta continuam sem informacao recuperavel. Ha testes numericos de radiancia acima65535, sombras, movimento, cobertura e metadados invalidos; bracket efetivo, ghosting e qualidade fisica desta politica ainda precisam ser medidos no SE.

A 0.6.0 acrescenta [referencia de preview](preview.md) ao acabamento. A saida continua JPEG SDR, sem gain map de exibicao HDR.

## Referencias

- [Apple: exposicao customizada](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)?changes=_2): limites do dispositivo e efeito sobre duracoes do preview.
- [Google, fotografia em pouca luz, 2019](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/): escolha conjunta de obturador/frames e tratamento especializado de ruido/movimento. A politica manual de tripe do BurstLab nao reproduz o motion metering ou AWB aprendido desse sistema.
