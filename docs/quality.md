# Qualidade antes do look

Escopo confirmado em 2026-10-22: cenas paradas, camera na mao de dia e tripe a noite. A meta e superar a camera padrao em comparacoes reais no SE 2022; isso ainda nao foi demonstrado.

## Diagnostico atual

- O alinhamento original tinha um perfil horizontal com 7/8 das colunas zeradas. A revisao corrige esse defeito e preserva a fase Bayer, mas continua sendo translacao global inteira. Nao corrige rotacao, paralaxe nem deslocamento fracionario.
- O merge e media aritmetica: qualquer residual de alinhamento entra na imagem. Ainda nao existe rejeicao robusta de movimento. Mais frames sem resolver isso podem aumentar o borrao.
- O denoise atual aplica media cromatica numa janela de 7x7 usando apenas diferenca de luma como guia. Duas cores diferentes com luma semelhante podem ser misturadas; a luma tambem recebe blend fixo de 25-50%. A intensidade nao depende de um modelo medido de ruido nem da contribuicao temporal efetiva.
- O brilho e normalizado pela mediana verde do RAW para 0,18. Isso pode levantar cenas predominantemente escuras e amplificar ruido. O caminho de cor faz clipping por canal antes da transferencia sRGB; nao ha compressao suave de realces nem tratamento de gamut.
- A transformacao DNG atual e uma aproximacao. Neutral->branco e um teste necessario, mas nao valida todos os matizes. CameraCalibration, AnalogBalance e ForwardMatrix nao sao usados. Verificar os tags reais antes de ampliar o modelo.
- Subexposicao fixa de -0,5 EV nao considera movimento, luminosidade ou risco real de clipping. A exposicao parte do AE de preview, sem estimar tremor nem selecionar o frame de referencia mais nitido.

Nenhuma dessas observacoes de codigo mede quanto cada fator contribui na foto do usuario.

## Corrigir a metodologia anterior

Saturacao HSV media igual a da camera padrao nao demonstra fidelidade ou agradabilidade de cor. Variancia do Laplaciano pode crescer com ruido ou sharpening; sozinha nao demonstra detalhe. Desvio padrao de um recorte pode misturar textura, gradiente de iluminacao e ruido. Comparacoes entre JPEGs com enquadramento/exposicao diferentes sao exploratorias, nao criterios de aprovacao.

Nao aplicar outro multiplicador de saturacao nem aumentar o denoise para esconder erros upstream. Nao dobrar frames automaticamente antes de medir alinhamento e memoria.

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
