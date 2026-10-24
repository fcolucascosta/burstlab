# BurstLab: camera computacional no iPhone SE 2022

App proprio inspirado no pipeline do Project Indigo (Adobe Nextcam). Nao e um bypass nem uma copia do app da Adobe: e uma implementacao independente, guiada pelo artigo publico de engenharia e pela literatura aberta de fotografia computacional.

**Alvo:** iPhone SE 2022 (`iPhone14,6`), A15, 4 GB de RAM, camera unica de 12 MP (wide), iOS 27.

**Estado atual (0.8.0):** Foto seleciona12/16/20RAWs pelo sinal de sombras e modelo de ruido do primeiro RAW, priorizando qualidade dentro de um orcamento de memoria. Refina translacoes locais pares em guia verde e trata ruido espectral residual apos a fusao. Isso ainda nao e super-resolucao nem alinhamento subpixel. Noite/Longa continuam16frames com ate0,5s/frame. RAWs de diagnostico agora valem apenas para o proximo disparo, substituem o ensaio anterior, tem limite de512MiB e expiram ao usar o app depois de24horas; ha limpeza nos Ajustes. Icone incluido. A interface4:3, toque para foco/exposicao e acabamento guiado pelo preview continuam. A verificacao de identidade/timestamps introduzida na0.7.0 continua rejeitando RAWs repetidos. Comparacao opcional com CIRAWFilter usa um DNG individual. Build nao aprova qualidade: superioridade sobre a camera padrao, latencia e pico de memoria exigem readback fisico da0.8.0.

**Primeiro readback0.7.0:**16RAWs distintos confirmados por SHA256,0rejeicoes e intervalo minimo0,506s entre timestamps em Noite0,5s/ISO160. O usuario relatou melhora acentuada. O novo enquadramento nao permite aprovar por esse teste a cor do tecido anterior; SNR/foco quantitativos, HDR e decoder Apple ainda precisam de ensaios especificos. O registro de identidades confirma a correcao das duplicatas neste teste, sem demonstrar qualidade geral em todas as cenas.

## Documentacao

- [Interface e foco por toque](docs/camera-ui.md).
- [Revelador Apple e pesquisa de ML](docs/apple-raw.md).

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
