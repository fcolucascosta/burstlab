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

## F1.5 - Sonda de burst RAW (concluida; calibracao em andamento)

- [x] Implementada no app: captura sequencial de 8 frames RAW com tempo por frame, estatisticas de nivel (min/media/max), FourCC, bytes/linha e estado termico.
- [x] Relatorio no aparelho: 8 frames em 0,47 s (**17,0 fps**), 4032x3024x16 bit (8064 B/linha, 24,4 MB/frame), termica **nominal**, min ~1950-2000 / media 2304 / max 11,1-13,0k.
- [ ] Calibracao do frame inteiro (build 0.1.2): histograma completo, percentis, modas (nivel de preto), saturacao, alinhamento de bits e medias por fase CFA.

**Criterio de aceite**: taxa de burst e comportamento termico atendidos (17 fps; nominal). O numero de frames do F2 parte de 8-12 e testa 16.

## F2 - Nucleo de burst

- Captura de N frames RAW (ring buffer) com exposicao constante subexposta.
- Budget medido: 24,4 MB/frame; 8 frames = 195 MB; acumulador UInt32 = 48,8 MB; pico alvo < 150 MB.
- Alinhamento (FFT/piramide) e merge robusto.
- Demosaic + WB + saida JPEG.
- Metricas: SNR em sombras vs frame unico; detalhe (MTF); ghosting.

**Criterio de aceite (hipotese a testar)**: foto de 8 frames com SNR em sombras visivelmente melhor que o frame unico, sem artefatos de ghost em cena estatica, dentro do orcamento de memoria.

## F3 - Look natural

- Tone mapping global + realce local controlado; saturacao leve; sharpening leve.
- Comparacao com amostras de referencia.

## F4 - Modos

- Night (exposicoes longas, contagem de frames, deteccao de trip).
- Long Exposure (sum merge).

## F5 - UX pro

- Controles manuais (ISO, tempo, foco, WB, EV, no de frames).
- Ferramentas do viewfinder (histograma, zebra, nivel, loupe) e filmstrip.

## F6 - Avancado (stretch)

- Super-resolution multi-frame no zoom.
- Saida DNG propria.
- Gain map SDR/HDR (ISO 21496-1).
- Denoise por CoreML.
