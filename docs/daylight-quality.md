# Ajuste diurno 0.8.0

Pedido: corrigir acumulo de RAWs, incluir icone e tornar o ganho do empilhamento perceptivel no detalhe diurno. O usuario prefere qualidade a latencia e pediu selecao dinamica favorecendo mais quadros. O teste noturno anterior foi considerado bom; esta rodada muda a fusao e contagem do modo Foto.

Entradas reais copiadas por USB em reports/daylight-20261024: quatro bursts0.7.0 de8RAWs distintos (SE2022,ISO32), duas cenas externas matinais e duas com telhado/grades em sombra e rua ao sol. Comparacoes IMG_1050.HEIC e IMG_1058.HEIC da camera padrao. Arquivos pessoais ficam somente no computador, ignorados pelo git. Os RAWs noturnos antigos que ja haviam sido copiados continuam nos relatorios locais, mesmo depois da remocao no aparelho.

## Experimentos isolados

1. Retencao: commit separado, com migracao, prazo, orcamento, botao de limpeza e testes de filesystem. Veja diagnostic-storage.md.
2. Icone: commit separado; catalogo iOS opaco1024x1024. Conferencia do asset compilado e screenshot no build da versao.
3. Alinhamento: reprocessamento independente em Python mantem o mesmo ruido/operador temporal e compara translacao global com refinamento regional. Na cena84CE, o MSE entre frames caiu2756->1158DN2 no recorte do telhado e338175->141261DN2 na rua. Isso mede concordancia em uma entrada real, sem referencia limpa; nao e PSNR da foto final nem prova de melhor qualidade fisica. O prototipo inicial usa todos os pontos do bloco; o operador Swift usa64 pontos para conter custo. O readback numerico final distingue as duas implementacoes.
4. Ruido residual: a fusao passa a acumular os pesos do frame ancora e os quadrados dos pesos alternativos. A variancia espectral residual e256*variancia*((1+soma(w))^2+soma((1-w)^2))/N^2. Logo, areas com rejeicao nao assumem falsamente N amostras independentes. Um filtro Wiener suave, potencia/(potencia+varianciaResidual), preserva DC e atenua frequencias proximas do ruido; textura forte recebe ganho proximo de1. Forca inicial1, anterior0. Testes separam erro contra sinal sintetico limpo, preservacao de textura e rejeicao de movimento.
5. Contagem: Foto inicia com minimo12, mede quartil inferior do sinal verde no primeiro RAW e seleciona12/16/20. Alvo inicial SNR25 em condicoes ideais independentes, com cap20 e reserva32MiB no orcamento512MiB. Modelo ausente/invalido usa16. O quartil e um criterio de sinal, nao reconhecedor semantico de sombras: materiais pretos podem solicitar mais frames, sem por isso serem clareados. Esta politica nao implementa motion metering da GCam. Mais quadros nao prometem ganho se houver rejeicao/alinhamento ruim. Noite e Longa permanecem16.

## Implementacao e limites

Guia pela media dos dois verdes de cada quad CFA. Um deslocamento residual e selecionado por bloco32x32sensor, em janela de busca+-6px ao redor da translacao global. Custos comparados no mesmo suporte; melhoria deve superar o piso de ruido e10% do custo inicial. O mesmo deslocamento par orienta todas as fases CFA de cada patch de fusao; rejeicao temporal continua ativa. Bordas mantem o seed global. Nao ha recuperacao subpixel, demosaic conjunto multi-frame, detalhe gerado ou promessa de superioridade geral sobre Camera.

Sinalizacao no manifest schema5 registra a decisao de frames; processing.json registra blocos refinados/totais e forca residual. Custo do alinhamento entra no tempo de processamento existente. Picos de memoria/termica e qualidade instalada precisam ser medidos no SE. Testes e replays nao substituem comparacao fisica em enquadramento equivalente.

Referencias primarias: [HDR+2016](https://research.google/pubs/burst-photography-for-high-dynamic-range-and-low-light-imaging-on-mobile-cameras/), [analise IPOL2021](https://www.ipol.im/pub/art/2021/336/), [motion metering2019](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/), [super-resolucao2019](https://research.google/pubs/handheld-multi-frame-super-resolution/). Implementacao propria das equacoes; nenhum codigo AGPL foi incorporado ao app.

Reversao: voltar aos artefatos preservados0.7.0 para a fusao anterior. O commit do ajuste diurno pode ser revertido separadamente dos commits de armazenamento/icone. A reversao nao recupera RAWs de diagnostico que tenham expirado.
