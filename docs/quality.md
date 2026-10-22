# Qualidade antes do look

Escopo confirmado em 2026-10-22: cenas paradas, camera na mao de dia e tripe a noite. A meta e superar a camera padrao em comparacoes reais no SE 2022; isso ainda nao foi demonstrado.

## Diagnostico da 0.2.7

- O alinhamento original tinha um perfil horizontal com 7/8 das colunas zeradas. A revisao corrige esse defeito e preserva a fase Bayer, mas continua sendo translacao global inteira. Nao corrige rotacao, paralaxe nem deslocamento fracionario.
- O merge e media aritmetica: qualquer residual de alinhamento entra na imagem. Ainda nao existe rejeicao robusta de movimento. Mais frames sem resolver isso podem aumentar o borrao.
- O denoise da 0.2.7 aplica media cromatica numa janela de 7x7 usando apenas diferenca de luma como guia. Duas cores diferentes com luma semelhante podem ser misturadas; a luma tambem recebe blend fixo de 25-50%. A intensidade nao depende de um modelo medido de ruido nem da contribuicao temporal efetiva.
- O brilho e normalizado pela mediana verde do RAW para 0,18. Isso pode levantar cenas predominantemente escuras e amplificar ruido. O caminho de cor faz clipping por canal antes da transferencia sRGB; nao ha compressao suave de realces nem tratamento de gamut.
- A transformacao DNG atual e uma aproximacao. Neutral->branco e um teste necessario, mas nao valida todos os matizes. CameraCalibration, AnalogBalance e ForwardMatrix nao sao usados. Verificar os tags reais antes de ampliar o modelo.
- Subexposicao fixa de -0,5 EV nao considera movimento, luminosidade ou risco real de clipping. A exposicao parte do AE de preview, sem estimar tremor nem selecionar o frame de referencia mais nitido.

Nenhuma dessas observacoes de codigo mede quanto cada fator contribui na foto do usuario.

## Primeiro experimento: 0.2.8

A revisao 0.2.8 remove somente a media espacial de luminancia e conserva o filtro cromatico. A decisao veio do reprocessamento offline de um burst real apoiado: o filtro anterior reduzia a estrutura de luminancia repetivel junto com o ruido. O candidato preserva mais dessa estrutura com mais grao visivel. Isso ainda nao e validacao fisica da 0.2.8 nem comparacao com a camera padrao. RAWs, replay, limites das metricas e reversao permanecem nos relatorios locais; nao sao publicados no repositorio.

## Experimentos 0.2.9 e 0.3.0

Na 0.2.9 a media incondicional foi substituida por fusao por frequencia em blocos sobrepostos de cada fase Bayer. A discordancia com o primeiro frame reduz a contribuicao dos demais; o limiar usa NoiseProfile do DNG, quando acessivel, ou estimativa robusta da diferenca entre frames. O alinhamento continua global inteiro: essa rejeicao nao recupera detalhe perdido por tremor durante a exposicao, nem substitui alinhamento local/subpixel.

Na 0.3.0 o acabamento trabalha antes do clipping/gamma: um mapa guiado de luminancia logaritmica limita o levantamento local a um ponto, uma curva suave comprime realces e a compressao de gamut preserva luminancia/direcao cromatica. O fator cromatico 1,15 e uma escolha experimental de look, nao calibracao de fidelidade. A exposicao pela mediana verde e a matriz DNG simplificada ainda precisam de avaliacao. A saida continua JPEG SDR; nao ha gain map HDR.

Um burst real externo (ISO 32, aproximadamente 1/725 s) foi reprocessado offline com a mesma entrada para media, fusao e acabamento. A inspecao visual mostra reducao dos rastros dos carros e sombras mais legiveis; as previas usam agrupamento CFA 2x2, sem o demosaic e filtro cromatico finais. Isso nao mede qualidade da nova captura instalada, nem demonstra superioridade sobre a camera padrao. Testes Swift verificam FFT contra operador externo, integridade Bayer, ruido sintetico, mapa de tom contra NumPy/SciPy e propriedades de gamut/neutralidade.

## Exposicao e generalizacao: 0.3.1

O retorno no SE confirmou 0.3.0 instalada; o usuario relatou ausencia de arrasto nessa captura, com brilho baixo, pouca saturacao e ruido visivel. Nao extrapolar esse resultado para outras cenas.

A 0.3.1 muda somente o algoritmo de exposicao de renderizacao: media geometrica da luminancia linear sRGB em thumbnail, extremos de 1% aparados, piso para log e limites absolutos de ganho 0,5..24. A mediana passa a ser diagnostica. A ideia de medir a cena pela luminancia logaritmica vem de [Reinhard et al., 2002](https://www-old.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf); nao implementamos o operador completo do artigo. Key continua 0,18, e a identificacao automatica de cenas intencionalmente claras/escuras continua pendente.

Replays com primeiro RAW, mantendo o restante do acabamento, resultaram em aproximadamente +0,20 EV no interior ISO640, +0,56 EV no exterior claro e +0,61 EV no crepusculo. Previas CFA 2x2 nao avaliam detalhe nem ruido final. O medidor no app usa o mosaico fundido, portanto seus valores podem diferir. Testes incluem uma cena bimodal que atravessa 50% de area clara, onde a mediana pode saltar com pequeno reenquadramento. Comparar verde com luminancia mediana mudou apenas 1-2% nas tres cenas; essa diferenca isolada nao explica o escurecimento.

Com a coleta RAW ativada, processing.json registra tempo por etapa, estatisticas do medidor, deslocamentos e disponibilidade de NoiseProfile no callback. Os tempos excluem exportacao RAW e salvamento na fototeca. Nenhuma medida de pico de memoria foi adicionada.

Cor e denoise permanecem iguais a 0.3.0. Clarear pode tornar ruido mais visivel. A analise exploratoria dos pesos mostra contribuicoes temporais diferentes entre regioes/frequencias; o proximo ensaio de ruido precisa considerar ruido residual, movimento e textura, em vez de supor que oito frames contribuem igualmente. Antes de aprovar um look geral, ampliar a coleta para iluminantes diversos, pele, folhagem, contraluz e noite apoiada. Os tres bursts atuais nao comprovam generalizacao.

## Metricas e comparacoes

Saturacao HSV media igual a da camera padrao nao demonstra fidelidade ou agradabilidade de cor. Variancia do Laplaciano pode crescer com ruido ou sharpening; sozinha nao demonstra detalhe. Desvio padrao de um recorte pode misturar textura, gradiente de iluminacao e ruido. Comparacoes entre JPEGs com enquadramento/exposicao diferentes sao exploratorias, nao criterios de aprovacao.

Nao tratar um aumento de saturacao como correcao de erros upstream. Avaliar o ajuste de look separadamente da calibracao e nao aumentar o denoise para esconder erros de fusao. Nao dobrar frames automaticamente antes de medir alinhamento e memoria.

## Coleta reproduzivel

No painel de informacoes, ativar **Guardar RAWs para comparacao** apenas para os ensaios. O app preserva os oito buffers originais com stride, um DNG de referencia quando disponivel e um manifest. A escrita ocorre depois da captura. Os arquivos ficam em **Arquivos > No Meu iPhone > BurstLab > Ensaios**; ocupam aproximadamente 220 MB por burst e podem ser copiados para o computador. A opcao e desligada por padrao. Um diretorio sem manifest e uma coleta incompleta. Nao e necessario publicar fotos no repositorio.

Capturar as mesmas cenas com a camera padrao, mesmo ponto de vista, luz estavel e lente limpa. Fazer pelo menos tres repeticoes por condicao:

1. Dia, tripe: tecido, texto pequeno, folhagem, objeto colorido e superficies neutras. Isola cor/detalhe sem tremor.
2. Dia, na mao: mesma cena e enquadramento aproximado; testa alinhamento e escolha de referencia.
3. Noite, tripe: cena parada com areas escuras e uma fonte de luz; testa ruido e protecao de realces.

Preservar originais e EXIF da camera padrao. O DNG de referencia preserva metadados da captura RAW; o JPEG customizado ainda nao preserva ISO/tempo. Medir latencia e memoria separadamente dos ensaios com escrita de RAW, porque a coleta adiciona custo e um DNG em memoria.

## Ordem dos experimentos (uma alteracao por vez)

1. **Alinhamento e merge:** repetir o mesmo burst com frame unico, media alinhada e merge robusto. Medir residual local e visualizar bordas/texturas a 100%; referencia mais nitida e fallback local quando frames discordam. Subpixel deve respeitar CFA; nao interpolar o mosaico como uma imagem monocromatica.
2. **Denoise:** desligado, cromatico leve e variante atual, com o mesmo merge/exposicao/cor. Preservar textura e contornos cromaticos, aceitando grao fino. Calibrar ruido em RAW por ISO e sinal antes de fixar thresholds do merge.
3. **Cor e tom:** comparar o DNG de referencia em conversor estabelecido com nossa conversao. Conferir iluminantes, matriz e branco; depois estudar curva tonal e gamut. Carta de cores permite Delta E; objetos coloridos sem referencia so permitem avaliacao visual de preferencia.
4. **Captura:** comparar politicas para dia na mao e noite no tripe. Limite de tempo e contagem de frames sao resultados de medicao, nao numeros universais. Tripod mode explicito pode ser preferivel a uma deteccao nao validada.

Aprovar apenas quando o ganho se repetir e nao vier de alisamento de textura ou halos. Registrar cena, versao, parametros, evidencia e reversao em reports/. Build verde comprova compilacao, nao melhora fotografica.

## Fontes primarias consultadas

- [Hasinoff et al., HDR+, 2016](https://research.google/pubs/burst-photography-for-high-dynamic-range-and-low-light-imaging-on-mobile-cameras/): alinhamento, modelo de ruido e fusao robusta.
- [Monod, Delon e Veit, IPOL 2021](https://www.ipol.im/pub/art/2021/336/): analise e implementacao aberta do HDR+.
- [Liba et al., 2019](https://research.google/pubs/handheld-mobile-photography-in-very-low-light/): escolha conjunta de tempo e numero de frames com base em movimento.
- [Levoy e Kainz, Indigo, 2025](https://research.adobe.com/articles/indigo/indigo.html): suavizacao espacial minima e ajustes leves de look.
- [Adobe DNG SDK, dng_color_spec](https://android.googlesource.com/platform/external/dng_sdk/+/refs/heads/android14-d2-s5-release/source/dng_color_spec.h): etapas de calibracao de cor que o modelo simplificado precisa conferir.
