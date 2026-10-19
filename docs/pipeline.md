# Pipeline: do Indigo ao BurstLab

Este documento resume o que o Project Indigo faz com base em fontes publicas (o artigo da Adobe e a literatura aberta) e define o que vamos implementar no BurstLab, com os limites do iPhone SE 2022.

## O que o Indigo faz (fonte: artigo da Adobe/Nextcam, 2025)

- **Frontend**: captura um burst de frames RAW com exposicao constante e subexposta; alinha e combina (merge) ate 32 frames. Menos ruido, mais alcance dinamico, menos suavizacao espacial.
- **DNG opcional**: o resultado merged ainda "quase RAW" pode ser salvo como DNG (1 cor por pixel, sem demosaic). O look (SDR/HDR) fica embutido no DNG de forma nao destrutiva.
- **Look (Adaptive Color Profile AI)**: grade de curvas de ganho (Profile Gain Table Map, PGTM) para brilho + LUTs 3D (RGBTs) para cor, com ajustes semanticos sutis.
- **Backend**: tone mapping suave, sharpening e cor; JPEG final com base SDR + gain map HDR (formato hibrido, ISO 21496-1).
- **Photo mode**: zero shutter lag (viewfinder ja captura RAW continuamente; o frame anterior ao toque vira referencia do merge).
- **Night mode**: exposicoes de ate 1 s e ate 32 frames; detecta trip e alonga a exposicao.
- **Long Exposure**: troca o merge robusto por soma de frames (efeito "seda na agua"), full-res.
- **Super-resolution multi-frame**: com zoom >= 2x, usa o tremor natural para obter offsets subpixel e recuperar detalhe real (sem alucinar).
- **Controles pro**: foco, tempo de exposicao, ISO, compensacao de exposicao, balanco de branco (temperatura/tinta) e **numero de frames** do burst.

## Decisoes para o SE 2022 (iPhone14,6, A15, 4 GB, camera unica 12 MP)

**Adotamos**: burst RAW de exposicao constante subexposta; alinhamento + merge robusto; demosaic proprio; tom natural (curva global + realce local leve); JPEG primeiro; controles pro; Night; Long Exposure; SR por burst.

**Adiamos**: DNG proprio (encoder completo), gain map HDR, zero shutter lag (buffer circular continuo), look por IA/PGTM aprendido e denoise ML.

**Limites que mandam no projeto**:
- Camera unica de 12 MP: sem ultrawide/tele; SR apenas digital via burst.
- 4 GB de RAM: o pico de memoria deve ficar bem abaixo do limite de Jetsam. Contas medidas: RAW 12 MP em container de 16 bits = 4032 x 3024 x 2 = 24.385.536 bytes (~24,4 MB/frame); 8 frames ~195 MB; 16 frames ~390 MB. Acumulador UInt32 full-res = 48,8 MB; orcamento alvo de trabalho ~150 MB por burst de 8.
- Processar por tiles no Metal, alinhar em resolucao reduzida (ex. 1/4) e aplicar warp em tiles full-res.
- Termica num corpo pequeno: bursts curtos e limites de frames por modo.
- Exposicao maxima de 0,5 s por frame (medida): Night soma mais frames, nao frames de 1 s.

## Algoritmos planejados (com referencias abertas)

1. **Captura**: AVFoundation com Bayer RAW (`availableRawPhotoPixelFormatTypes`), exposicao manual; fallback para YUV processado se RAW nao existir no SE (a sonda F1 responde isso).
2. **Alinhamento**: estimativa grosseira por correlacao de fase (FFT) ou piramide Lucas-Kanade no canal luma; refinamento por tiles (referencia: FFT-based alignment do HDR+).
3. **Merge**: media robusta com rejeicao de outliers/ghosting (mediana local + filtro Wiener híbrido 2D/3D do HDR+); ruido cai ~sqrt(N).
4. **Demosaic**: Malvar-He-Cutler como primeiro passo.
5. **Balanco de branco**: grey-world robusto; evolucao opcional para metodo aprendido (referencia: auto WB da low-light paper).
6. **Tone mapping**: curva global film-like + realce local com filtro bilateral/guided (Durand & Dorsey), evitando halos e o look "HDR-ish".
7. **Sharpening**: leve, sem ringing.
8. **SR**: fusao multi-frame com offsets subpixel e reconstrucao em grade regular (referencia: Wronski et al. 2019).

## Metricas e evidencia (regra do projeto)

- SNR em sombras (cartao cinza), MTF (estrela de Siemens), ghosting (cena com movimento), latencia por captura e comportamento termico.
- Nenhuma afirmacao de qualidade sem medicao no aparelho. Cada fase termina com um IPA instalado e um relatorio em `reports/`.

## Respostas da sonda no SE 2022 (2026-10-19)

- **RAW Bayer: sim.** Formato `rgg4` (14-bit Bayer RGGB), buffer unico de 4032 x 3024. O risco principal da F1 esta eliminado.
- **Exposicao maxima: 0,5 s** por frame no formato ativo (a minima aparece como 0.000020s a 0.500000s desde a build 0.1.1). O Night do Indigo usa ate 1 s por frame; no SE vamos somar mais frames (32 x 0,5 s = 16 s de integracao maxima).
- **ISO: 22-2112** no formato processado ativo; o formato RAW pode ter faixa diferente (medir na sonda de burst).
- **Memoria fisica: 3,79 GB**, confirmando o orcamento conservador de frames.
- **Formatos processados**: 420f, 420v, BGRA.

### Resultados da sonda de burst RAW (2026-10-19)

- **Taxa: 17,0 fps** (8 frames em 0,47 s). Primeiro frame 103,2 ms (aquecimento); seguintes 49,8-53,7 ms (~18,6-20,0 fps instantaneos). Buffer 4032x3024, 8064 B/linha (16 bits/pixel), FourCC `rgg4`.
- **Niveis no frame 1 (amostragem 1/64)**: min ~1942-1999, media 2304, max 11134-12962 (variacao entre frames). A media constante em 2304 sugere pedesta-lo de preto fixo; falta confirmar no histograma completo.
- **Termica**: nominal ao final de 8 frames.
- **Dados iniciais de alinhamento**: os maximos incluem valores impares (ex. 11819, 12505), o que descarta 14 bits alinhados a esquerda (2 bits baixos sempre zero). Tudo indica **alinhado a direita**, com pedesta-lo de preto perto de 2000-2048 DN; o histograma completo da 0.1.2 confirma a moda exata e a saturacao.

### Ainda em aberto

- Nivel de preto/saturacao, alinhamento de bits e padrao CFA exatos (analise de frame inteiro na 0.1.2).
- Custo termico de bursts de 16-32 frames.
- Faixa de ISO/exposicao do formato RAW (a sonda atual reporta a do formato ativo).

## Referencias

- Marc Levoy, Florian Kainz: *Project Indigo: a computational photography camera app* (Adobe Research, 2025).
- Hasinoff et al.: *Burst photography for HDR and low-light imaging on mobile cameras* (SIGGRAPH Asia 2016) - HDR+.
- Liba et al.: *Handheld Mobile Photography in Very Low Light* (SIGGRAPH Asia 2019).
- Monod: *An Analysis and Implementation of the HDR+ Burst Photography Pipeline* (IPOL 2021) - implementacao aberta de referencia.
- Wronski et al.: *Handheld Multi-Frame Super-Resolution* (SIGGRAPH 2019).
- Durand, Dorsey: *Fast Bilateral Filtering for the Display of High-Dynamic-Range Images* (SIGGRAPH 2002).
- Malvar, He, Cutler: *High-Quality Linear Interpolation for Demosaicing of Bayer-Patterned Color Images* (ICASSP 2004).
- ISO 21496-1 (gain map para imagens SDR/HDR hibridas).
