# BurstLab: camera computacional no iPhone SE 2022

App proprio inspirado no pipeline do Project Indigo (Adobe Nextcam). Nao e um bypass nem uma copia do app da Adobe: e uma implementacao independente, guiada pelo artigo publico de engenharia e pela literatura aberta de fotografia computacional.

**Alvo:** iPhone SE 2022 (`iPhone14,6`), A15, 4 GB de RAM, camera unica de 12 MP (wide), iOS 27.

**Estado atual (0.6.0):** Foto usa 8 RAWs; Noite/Longa usam 16 e ate 0,5 s/frame em tripe. Noite pode intercalar quatro exposicoes curtas para realces e combina as duas exposicoes antes do demosaic. O acabamento passa a consultar uma amostra SDR do preview para orientar brilho/contraste, preservando materiais escuros em vez de leva-los indiscriminadamente ao cinza medio. O preview nao fornece os pixels da foto final. A captura longa foi confirmada em ensaios anteriores; a nova referencia de preview e o bracket HDR ainda exigem readback e comparacao fisica. Ruido, registro local/subpixel, Noite na mao, termica/memoria e gain map HDR continuam exigindo trabalho; build nao aprova qualidade fotografica.

## Documentacao

- [Preview como referencia do acabamento](docs/preview.md): contraste, preservacao dos pretos, fallback e readback.

- [Noite e longa exposicao em tripe](docs/night.md): politica de captura, uso dos modos e evidencia pendente.

- [Auditoria HDR+, Indigo e GCam mods](docs/pipeline-audit.md): inspecao estatica, referencias executaveis e lacunas do pipeline.

- [Qualidade e ensaios reproduziveis](docs/quality.md): prioridade fotografica, limites conhecidos e comparacoes com a camera padrao.

- [Pipeline e pesquisa](docs/pipeline.md): o que o Indigo faz, o que vamos implementar, algoritmos e limites do SE.
- [Build e instalacao no Windows](docs/build.md): GitHub Actions + iLoader.
- [Roadmap](docs/roadmap.md): fases e criterios de aceite.

## Estrutura

- `Apple/`: app SwiftUI + AVFoundation (captura e sonda).
- `Shared/`: logica pura testavel (configuracoes de burst, orcamento de memoria).
- `Tests/`: testes Swift.
- `tools/`: gerador do projeto Xcode, validador estrutural, empacotador de IPA e testes do empacotador.
- `.github/workflows/apple-build.yml`: compila em runner macOS e publica o IPA unsigned.

## Referencias principais

- Marc Levoy e Florian Kainz, [Project Indigo: a computational photography camera app](https://research.adobe.com/articles/indigo/indigo.html), Adobe Research, 2025.
- Hasinoff et al., [Burst photography for high dynamic range and low-light imaging on mobile cameras](http://graphics.stanford.edu/papers/hdrp/hasinoff-hdrplus-sigasia16.pdf), SIGGRAPH Asia 2016.
- Liba et al., [Handheld Mobile Photography in Very Low Light](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/), SIGGRAPH Asia 2019.
- Monod, [An Analysis and Implementation of the HDR+ Burst Photography Pipeline](https://hal.science/hal-03384097v1/document), IPOL 2021.
- Wronski et al., [Handheld Multi-Frame Super-Resolution](https://research.google/pubs/handheld-multi-frame-super-resolution/), SIGGRAPH 2019.
- [Publicacoes de Marc Levoy](https://graphics.stanford.edu/~levoy/publications.html).
