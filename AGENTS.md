# Escopo e regras persistentes

- Alvo unico: iPhone SE 2022 (iPhone14,6, A15, 4 GB, iOS 27). Somente target iPhone; sem target Mac.
- Build: GitHub Actions (runner macOS) gera IPA unsigned; iLoader 2.3.8 no Windows assina e instala. Nunca enviar credenciais Apple ao repositorio nem ao GitHub.
- Evidencia: distinguir evidencia estatica, build e efeito fisico medido. Nao afirmar qualidade de captura, merge ou look sem medicao no aparelho.
- Preservar os checks de empacotamento (arm64 de device, bundle unsigned, sem mobileprovision).
- Relatorios locais ficam em `reports/` (ignorado pelo git).
- Metodologia: uma mudanca por vez, com readback e reversao documentada (padrao hy300-lab).
- Nomes: app/repo BurstLab; bundle `dev.lucas.burstlab.ios`.
