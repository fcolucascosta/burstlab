# Ciclo de vida dos RAWs de diagnostico

O uso normal processa os buffers em memoria e salva apenas o JPEG na fototeca. O diagnostico e descartavel: a opcao e local a tela, desliga no disparo ou ao sair do app e nunca e reativada pelo antigo UserDefaults persistente.

Um ensaio substitui o anterior, com limite de 512 MiB, reserva de 64 MiB livres para a escrita e exclusao do backup. A exportacao interrompida ou com falha e removida. Na abertura/retorno ao app e depois do processamento, a limpeza mantem somente o ensaio completo mais recente, com menos de 24 horas; a migracao tambem elimina o acumulo das versoes anteriores. O prazo e aplicado quando o app executa, sem prometer execucao de limpeza em segundo plano no iOS. Ajustes mostra o tamanho e permite apagar os diagnosticos.

Somente diretorios UUID diretamente em Documents/Ensaios sao gerenciados. Links simbolicos e pastas de outros nomes nao sao atravessados nem apagados. A fototeca nao participa dessa limpeza. Captura, comparador Apple e limpeza usam a mesma fila de processamento para evitar apagar uma exportacao em andamento.

Readback0.8.0: testes de filesystem cobrem migracao, expiracao, captura incompleta, substituicao, orcamento e isolamento de pastas/links; os84testes Swift,9de empacotamento e builds nativos passaram. Quatro ensaios diurnos foram copiados com32hashes verificados e removidos do aparelho, liberando824440076bytes; as outras27pastas estavam vazias. A migracao automatica instalada ainda exige teste fisico; veja daylight-quality.md. Reversao: git revert do commit desta alteracao; isso restaura o comportamento anterior, mas nao recupera diagnosticos ja expirados.
