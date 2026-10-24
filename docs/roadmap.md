# Roadmap

Cada fase termina com um IPA instalado no SE 2022 e um relatorio de evidencia em `reports/` (nao versionado).

## F0 - Pesquisa e decisoes (concluida parcialmente)

- [x] Documento de pipeline e algoritmos (`docs/pipeline.md`).
- [x] Referencias abertas mapeadas (HDR+, IPOL, low-light, SR).
- [ ] Amostras de referencia do Indigo (DNG/JPEG) para analise de look.

## F1 - Esqueleto de captura (concluida)

- [x] Projeto Xcode gerado por script, workflow de CI e empacotador de IPA.
- [x] App SwiftUI com preview, sonda de capacidades e captura unica para a fototeca.
- [x] Primeiro build no GitHub Actions e instalacao pelo iLoader (0.1.0, run 39324304300).
- [x] Relatorio da sonda no aparelho: RAW `rgg4` (14-bit RGGB) confirmado; exposicao ate 0,5 s; ISO 22-2112; 3,79 GB.

## F1.5 - Sonda de burst RAW (concluida)

- [x] Implementada no app: captura sequencial de 8 frames RAW com tempo por frame, estatisticas de nivel (min/media/max), FourCC, bytes/linha e estado termico.
- [x] Relatorio no aparelho: 8 frames em 0,47 s (**17,0 fps**), 4032x3024x16 bit (8064 B/linha, 24,4 MB/frame), termica **nominal**, min ~1950-2000 / media 2304 / max 11,1-13,0k.
- [x] Calibracao do frame inteiro (0.1.2): 14 bits alinhados a direita, branco **16383**, preto **2112**, CFA **RGGB**, faixa util 14271 DN.

**Criterio de aceite**: taxa de burst e comportamento termico atendidos (17 fps; nominal). O numero de frames do F2 parte de 8-12 e testa 16.

## F2 - Nucleo de burst (v1 implementada; validacao no aparelho pendente)

- [x] Captura RAW com exposicao constante (exposicao customizada,-0,5EV) e foco travado; Foto0.8.0 seleciona12/16/20frames pelo sinal/modelo de ruido do primeiro RAW, com prioridade de qualidade e limite de payload. Readback fisico da adaptacao pendente.
- [x] Alinhamento por projecoes (translacao inteira, arredondada para par); media inicial substituida por fusao por frequencia na 0.2.9.
- [x] Demosaic Malvar-He-Cutler, transformacao de cor DNG com WB alternativo, normalizacao global de exposicao, denoise espacial e JPEG na fototeca.
- Memoria calculada: 24,4 MB/frame; os 8 RAW retidos ja ocupam 195 MB. Bayer merged = 24,4 MB, RGB = 36,6 MB; denoise e rotacao adicionam buffers. A 0.2.9 reutiliza os buffers FFT e acumula uma fase CFA por vez; remove os acumuladores/contagens inteiros anteriores, mas mantem os 8 RAW. Pico residente ainda nao medido e o antigo alvo de 150 MB continua excedido so pelos frames retidos.
- [ ] Validacao no aparelho: SNR em sombras vs frame unico, ghosting, cores, latencia e pico de memoria.
- [x] Merge por frequencia com referencia privilegiada e limiar guiado por ruido (0.2.9); teste numerico e replay real, aceite fisico pendente.
- [x] Refinamento local par em guia verde e acabamento espectral guiado pela variancia residual (Foto0.8.0); testes/replay, aceite fisico pendente. Ver [ajuste diurno](daylight-quality.md).
- [ ] Alinhamento subpixel/piramide, selecao da ancora e medida das contribuicoes efetivas.
- Foto0.8.0 pode reter487710720bytes so nos20RAWs; isso e um orcamento de payload, nao pico residente medido. Continua necessario medir memoria/termica no SE.

## F3 - Look natural

- Mapa local limitado a 1 EV, shoulder e compressao de gamut implementados na 0.3.0; ajuste cromatico experimental 1,15. Aceite fisico pendente; sharpening nao implementado.
- Comparacao com amostras de referencia.
- [x] Compressao de iluminacao forte e shoulder racional (0.4.1); bracket de realces Noite (0.5.0), com aceite fisico pendente.
- [x] Referencia de luminancia/contraste do preview, curva monotona e exportacao do proxy (0.6.0); implementacao e testes, aceite fisico pendente. Ver [preview](preview.md).
- [ ] Medir ruido/detalhe e correspondencia entre proxy, preview visto e JPEG no aparelho; calibrar diferentes iluminantes e materiais pretos.

## F4 - Modos

- [x] Auditoria0.7.0 identificou duplicatas RAW em Noite e implementou cadencia/verificacao por pixels e timestamps.
- [x] Primeiro readback0.7.0 confirmou16SHA256 distintos,0rejeicoes e timestamps espacados>=0,506s em Noite0,5s/ISO160. Confirmacao limitada a este ensaio; SNR e generalizacao pendentes.

- [x] Noite em tripe:16frames, obturador ate0,5s, troca ISO por tempo ao mesmo produto solicitado e fusao robusta (0.4.0). Validacao fisica pendente.
- [x] Longa em tripe:16frames, acumulacao alinhada com pesos iguais normalizada, para rastros (0.4.0). Validacao fisica pendente.
- [ ] Noite na mao, deteccao automatica de estabilidade e politica de movimento/numero de frames.
- [ ] Medir memoria/termica do burst16 e efeitos dos intervalos entre fotos na longa exposicao.

Detalhes e limites em [Noite e longa exposicao](night.md). Ate0.3.3, defaults Noite/Longa nao estavam conectados a captura: o app sempre acionava Foto. O primeiro ensaio noturno recebeu aproximadamente0,19s de exposicao somada, apesar de13s de processamento. Esta lacuna nao era resolvida por ajustes de cor/denoise.

## F5 - UX pro

- [x] Enquadramento4:3, foco/exposicao por toque, grade, obturador/modos e revisao da ultima foto (0.7.0); layout revisado em simulador SE, foco fisico pendente.
- [x] Comparacao sob demanda do ultimo DNG com CIRAWFilter Apple e registro do decoder efetivo (0.7.0); [protocolo](apple-raw.md), validacao fisica pendente.
- [x] Icone e diagnostico descartavel: proxima foto apenas, limite512MiB, prazo24h aplicado no uso do app, migracao e limpeza nos Ajustes (0.8.0). [Ciclo dos RAWs](diagnostic-storage.md); readback automatico no aparelho pendente.

- Controles manuais (ISO, tempo, foco, WB, EV, no de frames).
- Ferramentas do viewfinder (histograma, zebra, nivel, loupe) e filmstrip.

## F6 - Avancado (stretch)

- Super-resolution multi-frame no zoom.
- Saida DNG propria.
- Gain map SDR/HDR (ISO 21496-1).
- Denoise por CoreML.

## Revisao 0.2.7

- Correcao do perfil horizontal esparso; busca somente deslocamentos pares, com empate favorecendo zero.
- Validacao dos layouts RAW e metadados nao finitos; bordas espelhadas preservam a fase CFA.
- Um burst por vez ate terminar processamento e salvamento; callbacks associados por ID e limites de espera.
- Calibracao fixa 2112/16383 restrita ao RAW RGGB de 14 bits; nao e calibracao dinamica por frame.
- Testes sinteticos e build nao comprovam SNR, fidelidade de cor, ausencia de ghosting ou desempenho no aparelho.
