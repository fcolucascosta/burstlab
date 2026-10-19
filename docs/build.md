# Build e instalacao pelo Windows

O MacBook da empresa nao participa do fluxo. O app e compilado em um runner macOS do GitHub Actions, baixado como `.ipa` sem assinatura e assinado localmente pelo iLoader no Windows, o mesmo metodo validado no BudsLab.

## Compilar

1. Repositorio: `fcolucascosta/burstlab` (privado, a criar) com este conteudo.
2. Execute **Actions -> Apple build -> Run workflow**.
3. O runner roda os testes Swift (`swift test`), os testes do empacotador, compila para simulador e para iPhone fisico, e publica o artefato **BurstLab-iPhone-unsigned**.
4. Baixe o artefato e extraia `BurstLab-<versao>-unsigned.ipa` e `BurstLab-<versao>-build.json`. O empacotador nomeia os arquivos pela versao (ex.: `BurstLab-0.1.1-unsigned.ipa`), entao versoes antigas podem ficar juntas em `build/dist` sem se sobrescreverem.

O workflow nao pede Conta Apple, certificado nem perfil. O empacotador confere que o executavel e arm64 para iPhoneOS fisico, rejeita binario de simulador/bundle ja provisionado e registra o SHA-256 do IPA.

## Instalar pelo Windows

1. Use o iLoader 2.3.8 ja instalado (o Sideloadly falhou na autenticacao Apple nesta maquina; o iLoader e o caminho confirmado).
2. Conecte o iPhone ao Windows por cabo, desbloqueie e autorize **Confiar neste computador**.
3. Abra o iLoader, selecione o iPhone e use **Import IPA** com `BurstLab-<versao>-unsigned.ipa`.
4. Autentique sua Conta Apple no proprio iLoader (2FA por dispositivo confiavel). O GitHub nunca recebe esses dados.
5. Conclua a instalacao e autorize o app de desenvolvimento em **Ajustes -> Geral -> VPN e Gerenciamento de Dispositivo**, se solicitado. Ative o Modo de Desenvolvedor caso o iOS peca.

Assinaturas de desenvolvimento expiram; renove instalando de novo com a mesma Conta Apple.

## Solucao de problemas

- **iLoader nao lista o iPhone**: verifique o **Apple Mobile Device Service** (`services.msc`), configure inicio automatico e inicie. Reconecte o iPhone desbloqueado e aceite a confianca.
- **GSA HTTP 503 no Sideloadly**: erro conhecido nesta maquina; use o iLoader 2.3.8, que corrige esse caso.

## Proximo passo pratico

Criar o repositorio `burstlab` no GitHub, enviar este conteudo, rodar o workflow e instalar o IPA. O primeiro objetivo no aparelho e abrir o relatorio de capacidades (botao de informacao) e copiar o texto: ele responde se o SE 2022 oferece RAW e quais os limites de ISO/exposicao.
