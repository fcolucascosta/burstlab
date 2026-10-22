# Auditoria do pipeline: HDR+, Indigo e GCam mods

Data: 2026-10-22. Base do app: 0.2.8. Prioridade: cenas paradas, uso na mao de dia e tripe a noite; movimento incidental nao deve produzir esteiras.

## O que foi efetivamente examinado

- Implementacao Python dos autores do artigo IPOL: [amonod/hdrplus-python, commit 98ebf17](https://github.com/amonod/hdrplus-python/tree/98ebf1724196bc070c1248e0f8efa2df6c18b8ef). Lidos alignment.py, merging.py, finishing.py, params.py e os defaults de runHdrplus.py.
- Implementacao C++/Halide independente: [timothybrooks/hdr-plus, commit ef4dd2c](https://github.com/timothybrooks/hdr-plus/tree/ef4dd2ca53a51e105ed923557c726b253f05c13b). Lidos align.cpp, merge.cpp e finish.cpp. Nao e o codigo proprietario da Google Camera.
- [Artigo dos criadores do Indigo](https://research.adobe.com/articles/indigo/indigo.html) e [Adaptive Profile da Adobe](https://blog.adobe.com/en/publish/2024/10/14/the-adobe-adaptive-profile).
- [Notas de versao publicadas pelo BSG](https://www.celsoazevedo.com/files/android/google-camera/dev-bsg/f/dl403/) e o [guia de controles LibPatcher publicado junto aos mods](https://www.celsoazevedo.com/files/android/google-camera/dev-bsg/help/2/). Esses materiais documentam controles e observacoes; nao especificam integralmente o algoritmo ou fornecem os pesos dos modelos.

As referencias foram clonadas somente em build/research/ (ignorado). Tambem foi feita uma primeira inspecao estatica parcial do APK BSG MGC_9.4.103_V41_MGC, distribuido na pagina do desenvolvedor. Foram lidos o diretorio ZIP e duas bibliotecas nativas por HTTP Range, sem instalar nem executar o APK. O CRC dos membros extraidos foi conferido pelo zipfile; a assinatura do APK completo nao foi verificada e o pacote completo nao foi baixado. Nenhuma protecao foi removida, e o codigo-fonte proprietario nao foi recuperado.

Os dois projetos abertos possuem licencas diferentes; nesta rodada foram usados somente localmente como referencia cientifica, sem incorporar seu codigo ao app. A analise binaria e observacional: nomes em strings nao especificam o algoritmo, seu fluxo ativo ou seus pesos.

## Primeira inspecao estatica do mod BSG

O APK inspecionado tem 326.061.819 bytes e 21 entradas de bibliotecas .so. Foram extraidos localmente libgcastartup.so (126.820.376 bytes; SHA-256 d815d9cf56892f994b2d1b6fa5a6fe1976bcc6c3d61494bfa9ab4f3783641da1) e librampatcher.so (280.568 bytes). Registro completo, URLs, CRCs, hashes e amostra das strings em reports/quality-20261022/new-scenes/gcam-static-inspection.json. Os membros permanecem somente em build/research/gcam-bsg-9.4.103-v41/.

Em libgcastartup.so aparecem nomes JNI de inicializacao HDR+, callbacks de frame-base e chroma denoised, alem de caminhos internos relacionados a:

- requests/burst_builder e lib_gcam/base_frame: construcao do burst e frame-base;
- merge_raw/align_raw_frames e merge_raw/merge_raw: alinhamento/fusao RAW;
- spatial_merge e sabre/noise_model: fusao espacial e modelo de ruido;
- color/lookup_table e color/color_map_sampling: tabelas/amostragem de cor;
- tonemap/legacy/hdr_gain_map e tonemap/legacy/clarity: etapas de tom;
- lib_gcam/gyro_filter: processamento associado ao giroscopio.

Esses sao indicios estaticos reais da separacao de responsabilidades no binario desta versao. Nao demonstram que todos esses caminhos rodam em cada modo, nem revelam as funcoes completas ou fornecem parametros portaveis ao SE. A presenca de librampatcher.so e um inventario, nao prova de como cada controle do BSG modifica a biblioteca. Esta rodada nao analisa montagem completa, fluxo dinamico ou modelos aprendidos do aplicativo.

## Comparacao por etapa

| Etapa | Referencia estudada | BurstLab 0.2.8 | Implicacao concreta |
|---|---|---|---|
| Entrada | RAW linear, calibracao de preto/branco e ruido | Bayer RGGB de 14 bits, preto/branco fixos historicos | O DNG real contem NoiseProfile, que pode orientar rejeicao em vez de limiares fixos arbitrarios. |
| Captura | Politica de exposicao considera movimento nas publicacoes Google | EV fixo -0,5, exposicao do AE escalada, AF travado sem aguardar convergencia | Foco e tempo de cada frame precisam de telemetria; tempo curto nao corrige mistura de varias posicoes. |
| Referencia | Uma imagem ancora recebe tratamento privilegiado | Primeiro frame ancora o alinhamento, mas todos recebem o mesmo peso no merge | Escolher referencia e preservar seu conteudo quando os alternativos discordam. |
| Alinhamento IPOL | Piramide de quatro niveis, blocos locais, refinamentos | Projecoes globais, translacao inteira par | Movimento local, rotacao, paralaxe e subpixel continuam sem tratamento. |
| Merge IPOL | Wiener por frequencia em blocos, guiado pelo modelo de ruido; sobreposicao com janela cosseno | Media aritmetica, sem rejeicao local | A media transforma movimento incidental em multiplas copias. Esta e a prioridade estrutural. |
| Merge Halide | Pesos de blocos por distancia L1 a referencia, sobreposicao suave | Sem mapa de confianca | Mostra uma alternativa espacial mais simples, mas seus parametros numericos nao devem ser copiados entre sensores/escalas. |
| Denoise | IPOL atualiza a variancia depois da fusao; Halide separa a etapa cromatica | Filtro cromatico 7x7 apos conversao para 8 bits; luma preservada na 0.2.8 | O backend atual ainda nao e guiado por ruido residual real e pode misturar bordas de cores distintas. |
| Look HDR+ | Ajustes locais e globais de tom, separados da fusao | Mediana verde vira 0,18; multiplicacao e clipping por canal | A aparencia pode ficar sem contraste e com cromaticidade alterada perto do clipping; nao e apenas falta de um multiplicador de saturacao. |
| Look Indigo | PGTM para tom e RGBTs para ajustes de cor | Matriz camera->sRGB e transferencia sRGB | Matriz de calibracao nao substitui o perfil de renderizacao. O artigo nao fornece o modelo aprendido para replicar exatamente esse look. |
| GCam mods | Controles de noise model, merge, tom, contraste e saturacao | Parametros rigidos e etapas incompletas | Os nomes dos controles ajudam a separar responsabilidades; valores de XML de outro sensor nao constituem calibracao do SE. |

## Codigo de merge examinado

No [merging.py do IPOL](https://github.com/amonod/hdrplus-python/blob/98ebf1724196bc070c1248e0f8efa2df6c18b8ef/package/algorithm/merging.py), a diferenca entre coeficientes de referencia e alternativo define um peso dependente do ruido. Concordancia permite somar informacao; discordancia desloca o resultado para a referencia. O tratamento e feito separadamente nas quatro fases CFA. As janelas e sobreposicoes evitam emendas de blocos.

No [merge.cpp Halide](https://github.com/timothybrooks/hdr-plus/blob/ef4dd2ca53a51e105ed923557c726b253f05c13b/src/merge.cpp), a confianca e calculada por distancia L1 em blocos reduzidos e aplicada ao Bayer. E outra implementacao, com compromissos diferentes; nao deve ser descrita como equivalente bit a bit a Google Camera ou a implementacao IPOL.

O estudo da Google de 2019 sobre [fusao e super-resolucao](https://research.google/pubs/handheld-multi-frame-super-resolution/) vai alem do HDR+ de 2016, com fusao de amostras CFA em RGB. Reproduzir a referencia de 2016 nao significa reproduzir toda a GCam moderna.

## Experimento executado

Um teste local usa o operador Wiener, as janelas e a reconstrucao originais do IPOL, carregados do checkout fixado. Apenas os decorators Numba foram retirados para permitir operacoes NumPy; o chamador usa FFT NumPy. Nao foram executados o alinhamento nem o acabamento completos. Fator temporal 75 (default da CLI); filtro espacial desligado para isolar a fusao.

Cenario sintetico: oito frames de 256x256, fundo texturado fixo, objeto retangular que muda de posicao, ruido independente com sigma 75 DN, seed 20261022. O resultado limpo da referencia e conhecido.

| Medida, unidades RAW | Frame unico | Media | Merge por frequencia IPOL |
|---|---:|---:|---:|
| Erro absoluto medio na regiao dos rastros | 59,20 | 284,23 | 28,62 |
| RMSE do fundo estatico nesse teste | 74,75 | 26,35 | 33,36 |

A referencia preserva o objeto ancora, aceitando mais ruido do que a media nas areas estaticas. Isso demonstra o mecanismo em um teste sintetico, nao recuperacao da foto real do onibus. Tambem foi processado um plano verde de um burst real apoiado da 0.2.7; ele nao tem movimento conhecido ou ground truth para validar a rejeicao de objetos.

Scripts, hashes e imagens de teste ficam em reports/quality-20261022/new-scenes/. As fotos do usuario e seus RAWs nao foram publicados no repositorio.

## Decisao de engenharia

Nao promover a 0.2.8 como solucao de ghosting ou cor: ela so removeu a suavizacao de luma. O proximo prototipo precisa substituir a media por confianca local/fallback para referencia, e registrar quantas amostras realmente contribuiram. Antes de lancar um novo IPA, comparar com a referencia executavel em:

1. Cena estatica ruidosa: ganho de ruido sem perda indevida de textura.
2. Objeto movendo sobre fundo estatico: rastro e ocupacao devem acompanhar a referencia, sem multiplas copias.
3. Movimento de camera, paralaxe e oclusao: nao confiar em alinhamento global fora de sua capacidade; fallback seguro e medido.
4. Variacao de ruido por sinal/ISO e entre canais CFA: taxas de falsa rejeicao registradas.
5. Bordas de blocos, recortes e stride: continuidade espacial e integridade Bayer verificadas.
6. Desempenho no A15: latencia, termica e pico de memoria medidos, sem inferir a partir do PC.

Tratar cor em um experimento separado: validar a transformacao do DNG com conversor de referencia, depois avaliar curva de contraste, gamut e cromaticidade em cenas pareadas com a camera padrao. O objetivo estetico continua sendo o usuario preferir o resultado; metricas de fidelidade so podem ser usadas quando ha referencia conhecida.

## Atualizacao de implementacao: 0.2.9 / 0.3.0

O comparativo acima registra o baseline 0.2.8. A 0.2.9 implementa fusao por frequencia independente, com FFT Accelerate 16x16 em cada fase CFA, sobreposicao de metade do bloco e janela cosseno. Um fixture do operador IPOL foi usado como oraculo numerico; o codigo AGPL nao foi incorporado ao app. O NoiseProfile de dois coeficientes orienta a variancia por sinal; se ausente no callback, usa-se estimativa MAD de diferencas alinhadas. Movimento dominante pode contaminar essa estimativa. Nao ha selecao da melhor ancora, alinhamento local/subpixel nem medida do numero efetivo de amostras.

A 0.3.0 adiciona mapa de sombras em thumbnail de luminancia linear, com filtro guiado em log ([He et al., ECCV 2010](https://kaiminghe.github.io/publications/eccv10guidedfilter.pdf)), ganho limitado a 1 EV, shoulder suave e compressao de gamut antes da transferencia sRGB. Nao reproduz o acabamento proprietario da GCam nem gera JPEG HDR com gain map. O ajuste cromatico 1,15 e experimental.

O replay do burst externo novo mostra visualmente menos copias de carros na mesma entrada. Seus RAWs tem ISO 32, tempo aproximadamente 1/725 s e fracao saturada de 0,0000328%. Isso sustenta a investigacao de merge/acabamento em vez de atribuir todos os rastros a exposicao longa. As previas agrupam CFA 2x2 e nao incluem o demosaic/filtro final. Desempenho no A15, ruido noturno e melhora fisica continuam pendentes.

## Readback e reversao do estudo original

Esta rodada nao altera o algoritmo do app nem gera nova versao. Os originais JPEG/RAW continuam preservados. O estudo e uma alteracao documental isolada; reversao por git revert do commit correspondente. As referencias em build/research/ e os relatorios em reports/ nao participam do IPA.
