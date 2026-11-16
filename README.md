Vigia Recife — Mapa Preventivo de Espaços Públicos
Projeto de extensão da Equipe SolarTec (UNINASSAU · ADS 2NA). Plataforma que organiza informações sobre espaços públicos do Recife em um Mapa Preventivo, com o Índice Preventivo e o Pulso do Recife, para cidadãos/turistas e servidores públicos.
Estrutura
```
vigia-recife/
├── backend/    API Node.js + Express (também serve o front-end)
├── database/   schema.sql (estrutura) e seed.sql (dados demonstrativos)
├── frontend/   index.html, css/, js/  (HTML, CSS e JavaScript puros + Leaflet)
└── docs/       ENDPOINTS.md
```
Como rodar
Requisitos: Node.js 18+ e PostgreSQL 12+.
```bash
createdb -U postgres vigia_recife        # ou crie o banco pelo pgAdmin
cd backend
cp .env.example .env                      # ajuste DATABASE_URL (usuário/senha)
npm install
npm run db:setup                          # cria tabelas, dados demonstrativos e contas de teste
npm start                                 # http://localhost:3000
```
Abra http://localhost:3000 no navegador. Para recomeçar o banco do zero: `npm run db:reset`.
Contas de teste (senha `123456`): `ana@email.com` (cidadão) · `marina@sesec.pe.gov.br` (servidor).
Testes rápidos da API
```bash
curl http://localhost:3000/api/health
curl http://localhost:3000/api/locais
curl http://localhost:3000/api/locais/1/pulso
curl -X POST http://localhost:3000/api/auth/login -H "Content-Type: application/json" \
     -d '{"email":"marina@sesec.pe.gov.br","senha":"123456","perfil":"servidor"}'
```
Tecnologias
Node.js, Express, PostgreSQL (`pg`), JWT, bcrypt, Leaflet + OpenStreetMap. Veja `docs/ENDPOINTS.md`.
Observações
Os dados em `seed.sql` são demonstrativos; o banco real (`schema.sql`) não traz dados fictícios.
O menu flutuante "8 telas" do protótipo permite navegar entre todas as telas e pode ser arrastado.
Próxima etapa (AV2): módulo de análise em Python para calcular o índice real.
