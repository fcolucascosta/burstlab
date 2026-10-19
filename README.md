# BurstLab: camera computacional no iPhone SE 2022

App proprio inspirado no pipeline do Project Indigo (Adobe Nextcam). Nao e um bypass nem uma copia do app da Adobe: e uma implementacao independente, guiada pelo artigo publico de engenharia e pela literatura aberta de fotografia computacional.

**Alvo:** iPhone SE 2022 (`iPhone14,6`), A15, 4 GB de RAM, camera unica de 12 MP (wide), iOS 27.

**Estado atual:** F1 concluida. A sonda no aparelho confirmou RAW Bayer (`rgg4`, 14-bit RGGB), exposicao ate 0,5 s por frame, ISO 22-2112 e 3,79 GB de memoria. Proximo passo: sonda de burst RAW (taxa, nivel de preto/saturacao, termica) antes do merge.

## Documentacao

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
