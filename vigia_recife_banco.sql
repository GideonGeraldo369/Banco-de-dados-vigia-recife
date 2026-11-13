-- =====================================================================
-- VIGIA RECIFE · Mapa Preventivo de Espaços Públicos
-- Banco de dados completo · PostgreSQL 12 ou superior
-- Estrutura (tabelas, funções, gatilhos e views) + dados de referência.
-- Não contém dados fictícios.
-- Equipe SolarTec · UNINASSAU · ADS 2NA
--
-- Origem das regras: slides, projeto de intervenção (ABNT) e
-- documentação AV1 (Banco de Oportunidades).
--
-- Como executar:
--   createdb -U postgres vigia_recife
--   psql -U postgres -d vigia_recife -v ON_ERROR_STOP=1 -f vigia_recife_banco.sql
-- Para recomeçar do zero:  dropdb vigia_recife  e repita os comandos.
--
-- Convenções
--   * nomes em português, minúsculos e sem acentos (snake_case);
--   * "status"   = semáforo do índice (Estável / Atenção / Prioridade);
--   * "situacao" = andamento de ocorrências, alertas e ações;
--   * toda nota vai de 0 a 100 (100 = melhor condição).
-- =====================================================================

BEGIN;

-- =====================================================================
-- 1. FUNÇÃO UTILITÁRIA
-- =====================================================================

CREATE FUNCTION fn_set_atualizado_em() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;

-- =====================================================================
-- 2. CATÁLOGOS (tabelas de apoio)
-- =====================================================================

-- Semáforo do Índice Preventivo.
-- As faixas (75 e 50) foram deduzidas dos exemplos da documentação AV1:
-- 92, 86 e 78 = Estável · 71 = Atenção · 43 = Prioridade.
CREATE TABLE niveis_status (
  codigo     VARCHAR(20) PRIMARY KEY,               -- estavel | atencao | prioridade
  nome       VARCHAR(30) NOT NULL,                  -- texto exibido no app
  emoji      VARCHAR(8)  NOT NULL,
  cor_hex    CHAR(7)     NOT NULL CHECK (cor_hex ~ '^#[0-9A-Fa-f]{6}$'),
  nota_min   SMALLINT    NOT NULL CHECK (nota_min BETWEEN 0 AND 100),
  nota_max   SMALLINT    NOT NULL CHECK (nota_max BETWEEN 0 AND 100),
  gravidade  SMALLINT    NOT NULL UNIQUE,           -- 1 = menos grave ... 3 = mais grave
  CONSTRAINT ck_niveis_status_faixa CHECK (nota_min <= nota_max)
);

-- Fatores que entram no cálculo do índice (documentação AV1, seção 3).
-- "Horário" e "dia da semana" não são fatores: são o eixo do Pulso (pulso_horario).
CREATE TABLE fatores (
  id                 SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo             VARCHAR(30)  NOT NULL UNIQUE,
  nome               VARCHAR(60)  NOT NULL,
  descricao          TEXT,
  peso               NUMERIC(5,2) NOT NULL CHECK (peso >= 0),  -- peso relativo na média ponderada
  ordem              SMALLINT     NOT NULL DEFAULT 0,
  exibir_no_detalhe  BOOLEAN      NOT NULL DEFAULT FALSE,      -- aparece nas barras da tela de detalhes
  ativo              BOOLEAN      NOT NULL DEFAULT TRUE
);

-- Rótulos das barras de cada fator (ex.: Fluxo de pessoas = Baixo / Moderado / Alto).
CREATE TABLE fator_niveis (
  fator_id  SMALLINT    NOT NULL REFERENCES fatores (id) ON DELETE CASCADE,
  nivel     SMALLINT    NOT NULL CHECK (nivel BETWEEN 1 AND 3),   -- nº de barras preenchidas
  rotulo    VARCHAR(40) NOT NULL,
  PRIMARY KEY (fator_id, nivel)
);

-- Praça, parque, orla, centro histórico e ponto turístico.
CREATE TABLE tipos_local (
  id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo  VARCHAR(30) NOT NULL UNIQUE,
  nome    VARCHAR(60) NOT NULL
);

-- Perfil do passeio escolhido na tela "Quero evitar".
CREATE TABLE perfis_passeio (
  id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo  VARCHAR(30) NOT NULL UNIQUE,
  nome    VARCHAR(60) NOT NULL
);

-- Órgãos que recebem e tratam as ocorrências ("não saber qual órgão acionar").
CREATE TABLE orgaos (
  id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sigla     VARCHAR(20)  NOT NULL UNIQUE,
  nome      VARCHAR(150) NOT NULL,
  email     VARCHAR(150),
  telefone  VARCHAR(20),
  ativo     BOOLEAN NOT NULL DEFAULT TRUE
);

-- Categorias da tela "Comunicar problema":
-- Segurança, Iluminação, Limpeza, Infraestrutura, Aglomeração e Outro.
CREATE TABLE categorias_ocorrencia (
  id        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo    VARCHAR(30) NOT NULL UNIQUE,
  nome      VARCHAR(60) NOT NULL,
  icone     VARCHAR(8),                                   -- emoji exibido no app
  orgao_id  INTEGER REFERENCES orgaos (id),               -- órgão normalmente responsável
  ordem     SMALLINT NOT NULL DEFAULT 0
);

-- =====================================================================
-- 3. ACESSO: EQUIPES, USUÁRIOS E SERVIDORES
-- =====================================================================

-- Equipes de campo (a quem o servidor atribui as ações preventivas).
CREATE TABLE equipes (
  id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  orgao_id   INTEGER      NOT NULL REFERENCES orgaos (id),
  nome       VARCHAR(100) NOT NULL,
  descricao  TEXT,
  ativa      BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT uq_equipes_orgao_nome UNIQUE (orgao_id, nome)
);

-- Login único dos dois perfis: cidadão/turista e servidor público.
-- senha_hash deve receber um hash (ex.: bcrypt) gerado no back-end, nunca a senha.
CREATE TABLE usuarios (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome             VARCHAR(150) NOT NULL,
  email            VARCHAR(150) NOT NULL
                   CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  senha_hash       VARCHAR(255) NOT NULL,
  perfil           VARCHAR(10)  NOT NULL CHECK (perfil IN ('cidadao', 'servidor')),
  telefone         VARCHAR(20),
  ativo            BOOLEAN      NOT NULL DEFAULT TRUE,
  ultimo_login_em  TIMESTAMPTZ,
  criado_em        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  atualizado_em    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT uq_usuarios_id_perfil UNIQUE (id, perfil)    -- usada pela FK de servidores
);
CREATE UNIQUE INDEX ux_usuarios_email ON usuarios (lower(email));

-- Dados funcionais de quem tem perfil "servidor" (área do servidor).
-- A FK composta (usuario_id, perfil) garante que só usuários com perfil
-- "servidor" possam ter linha nesta tabela.
CREATE TABLE servidores (
  usuario_id  BIGINT      PRIMARY KEY,
  perfil      VARCHAR(10) NOT NULL DEFAULT 'servidor' CHECK (perfil = 'servidor'),
  orgao_id    INTEGER     NOT NULL REFERENCES orgaos (id),
  equipe_id   INTEGER     REFERENCES equipes (id),
  matricula   VARCHAR(30) NOT NULL,
  cargo       VARCHAR(100),
  CONSTRAINT fk_servidores_usuario
    FOREIGN KEY (usuario_id, perfil) REFERENCES usuarios (id, perfil) ON DELETE CASCADE,
  CONSTRAINT uq_servidores_matricula UNIQUE (orgao_id, matricula)
);

-- =====================================================================
-- 4. TERRITÓRIO: REGIÕES, LOCAIS E EVENTOS
-- =====================================================================

-- Região de monitoramento (ex.: um bairro). O painel do servidor conta
-- "regiões prioritárias / em atenção / estáveis".
CREATE TABLE regioes (
  id             INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome           VARCHAR(100) NOT NULL UNIQUE,
  rpa            SMALLINT CHECK (rpa BETWEEN 1 AND 6),     -- Região Político-Administrativa (opcional)
  centro_lat     NUMERIC(9,6) CHECK (centro_lat BETWEEN -90 AND 90),
  centro_lng     NUMERIC(9,6) CHECK (centro_lng BETWEEN -180 AND 180),
  geometria      JSONB,                                    -- polígono GeoJSON para colorir o mapa (Leaflet)
  ativa          BOOLEAN      NOT NULL DEFAULT TRUE,
  criado_em      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  atualizado_em  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT ck_regioes_centro CHECK ((centro_lat IS NULL) = (centro_lng IS NULL))
);

-- Espaço público monitorado.
CREATE TABLE locais (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  regiao_id      INTEGER      NOT NULL REFERENCES regioes (id),
  tipo_local_id  SMALLINT     NOT NULL REFERENCES tipos_local (id),
  nome           VARCHAR(150) NOT NULL,
  descricao      TEXT,
  endereco       VARCHAR(200),
  latitude       NUMERIC(9,6) NOT NULL CHECK (latitude  BETWEEN  -90 AND  90),
  longitude      NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  raio_metros    INTEGER      NOT NULL DEFAULT 150 CHECK (raio_metros > 0),  -- área de abrangência
  ativo          BOOLEAN      NOT NULL DEFAULT TRUE,
  criado_em      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  atualizado_em  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT uq_locais_regiao_nome UNIQUE (regiao_id, nome)
);

-- Eventos programados (fator "eventos programados" do índice).
CREATE TABLE eventos (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  local_id          BIGINT       NOT NULL REFERENCES locais (id) ON DELETE CASCADE,
  nome              VARCHAR(150) NOT NULL,
  descricao         TEXT,
  inicio_em         TIMESTAMPTZ  NOT NULL,
  fim_em            TIMESTAMPTZ  NOT NULL,
  publico_estimado  INTEGER CHECK (publico_estimado >= 0),
  criado_em         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT ck_eventos_periodo CHECK (fim_em > inicio_em)
);

-- =====================================================================
-- 5. ÍNDICE PREVENTIVO E PULSO DO RECIFE
-- =====================================================================

-- Nota (0 a 100) de um local em um instante.
--   simulado  = dado demonstrativo (AV1)
--   calculado = resultado do cálculo real (AV2)
--   previsto  = projeção do módulo de análise para instantes futuros
CREATE TABLE indices_preventivos (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  local_id       BIGINT      NOT NULL REFERENCES locais (id) ON DELETE CASCADE,
  referencia_em  TIMESTAMPTZ NOT NULL,                    -- instante a que a nota se refere
  nota           SMALLINT    NOT NULL CHECK (nota BETWEEN 0 AND 100),
  origem         VARCHAR(10) NOT NULL DEFAULT 'simulado'
                 CHECK (origem IN ('simulado', 'calculado', 'previsto')),
  calculado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_indices_local_ref_origem UNIQUE (local_id, referencia_em, origem)
);

-- Contribuição de cada fator para uma nota (barras da tela de detalhes).
CREATE TABLE indice_fatores (
  indice_id    BIGINT   NOT NULL REFERENCES indices_preventivos (id) ON DELETE CASCADE,
  fator_id     SMALLINT NOT NULL REFERENCES fatores (id),
  nota         SMALLINT NOT NULL CHECK (nota BETWEEN 0 AND 100),   -- 100 = condição ideal
  nivel        SMALLINT NOT NULL CHECK (nivel BETWEEN 1 AND 3),    -- barras preenchidas (1 a 3)
  valor_bruto  NUMERIC(12,2),                                      -- medida original (pessoas/h, nº de chamados...)
  PRIMARY KEY (indice_id, fator_id),
  FOREIGN KEY (fator_id, nivel) REFERENCES fator_niveis (fator_id, nivel)
);

-- Pulso do Recife: como cada local costuma variar ao longo do dia.
-- dia_semana segue EXTRACT(DOW): 0 = domingo ... 6 = sábado.
-- atencao_recomendada = hora em que o app recomenda atenção (ex.: 21h às 23h).
CREATE TABLE pulso_horario (
  local_id             BIGINT      NOT NULL REFERENCES locais (id) ON DELETE CASCADE,
  dia_semana           SMALLINT    NOT NULL CHECK (dia_semana BETWEEN 0 AND 6),
  hora                 SMALLINT    NOT NULL CHECK (hora BETWEEN 0 AND 23),
  nota                 SMALLINT    NOT NULL CHECK (nota BETWEEN 0 AND 100),
  amostras             INTEGER     NOT NULL DEFAULT 0 CHECK (amostras >= 0),
  fonte                VARCHAR(10) NOT NULL DEFAULT 'simulado'
                       CHECK (fonte IN ('simulado', 'historico', 'previsto')),
  atencao_recomendada  BOOLEAN     NOT NULL DEFAULT FALSE,
  atualizado_em        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (local_id, dia_semana, hora)
);

-- =====================================================================
-- 6. PARTICIPAÇÃO DO CIDADÃO
-- =====================================================================

CREATE SEQUENCE seq_protocolo_ocorrencia;

-- Problema comunicado (tela "Comunicar problema").
-- usuario_id NULL = relato anônimo (acompanhamento só pelo protocolo).
CREATE TABLE ocorrencias (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  protocolo      VARCHAR(20) NOT NULL UNIQUE
                 DEFAULT ('VR-' || to_char(now(), 'YYYY') || '-'
                          || lpad(nextval('seq_protocolo_ocorrencia')::TEXT, 6, '0')),
  local_id       BIGINT      NOT NULL REFERENCES locais (id),
  categoria_id   SMALLINT    NOT NULL REFERENCES categorias_ocorrencia (id),
  usuario_id     BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
  orgao_id       INTEGER     REFERENCES orgaos (id),       -- órgão responsável (sugerido pela categoria)
  origem         VARCHAR(15) NOT NULL DEFAULT 'cidadao'
                 CHECK (origem IN ('cidadao', 'servidor', 'sistema', 'orgao_externo')),
  descricao      TEXT        NOT NULL,
  latitude       NUMERIC(9,6) CHECK (latitude  BETWEEN  -90 AND  90),   -- localização enviada pelo celular
  longitude      NUMERIC(9,6) CHECK (longitude BETWEEN -180 AND 180),
  gravidade      SMALLINT    NOT NULL DEFAULT 2 CHECK (gravidade BETWEEN 1 AND 3),  -- 1 baixa · 2 média · 3 alta
  situacao       VARCHAR(15) NOT NULL DEFAULT 'recebida'
                 CHECK (situacao IN ('recebida', 'em_analise', 'encaminhada', 'resolvida', 'descartada')),
  ocorreu_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
  criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
  atualizado_em  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolvida_em   TIMESTAMPTZ,
  CONSTRAINT ck_ocorrencias_coord     CHECK ((latitude IS NULL) = (longitude IS NULL)),
  CONSTRAINT ck_ocorrencias_resolvida CHECK (resolvida_em IS NULL OR situacao = 'resolvida')
);
ALTER SEQUENCE seq_protocolo_ocorrencia OWNED BY ocorrencias.protocolo;

-- Fotos da ocorrência: o arquivo fica em disco/nuvem; aqui só o caminho.
CREATE TABLE ocorrencia_anexos (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ocorrencia_id  BIGINT       NOT NULL REFERENCES ocorrencias (id) ON DELETE CASCADE,
  url            VARCHAR(500) NOT NULL,
  tipo_mime      VARCHAR(80),
  tamanho_bytes  INTEGER CHECK (tamanho_bytes > 0),
  criado_em      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Linha do tempo da ocorrência (preenchida por gatilho, ver seção 9).
CREATE TABLE ocorrencia_historico (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ocorrencia_id      BIGINT      NOT NULL REFERENCES ocorrencias (id) ON DELETE CASCADE,
  situacao_anterior  VARCHAR(15),
  situacao_nova      VARCHAR(15) NOT NULL,
  responsavel_id     BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
  comentario         TEXT,
  criado_em          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Consultas "Quero evitar" / "Quero visitar" e a recomendação entregue.
CREATE TABLE consultas_recomendacao (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  usuario_id         BIGINT      REFERENCES usuarios (id) ON DELETE SET NULL,
  local_id           BIGINT      NOT NULL REFERENCES locais (id),
  intencao           VARCHAR(10) NOT NULL CHECK (intencao IN ('visitar', 'evitar')),
  horario_previsto   TIMESTAMPTZ NOT NULL,                 -- data e hora do passeio
  perfil_passeio_id  SMALLINT    REFERENCES perfis_passeio (id),
  nota_no_horario    SMALLINT    CHECK (nota_no_horario BETWEEN 0 AND 100),
  status_codigo      VARCHAR(20) REFERENCES niveis_status (codigo),
  recomendacao       TEXT        NOT NULL,
  criado_em          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 7. GESTÃO PREVENTIVA (área do servidor)
-- =====================================================================

-- Alerta para uma região e/ou local ("ALERTAS DA IA" do painel preventivo).
-- status_codigo = gravidade do alerta (atencao ou prioridade).
-- situacao      = andamento do tratamento.
CREATE TABLE alertas (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  regiao_id      INTEGER     REFERENCES regioes (id),
  local_id       BIGINT      REFERENCES locais (id),
  status_codigo  VARCHAR(20) NOT NULL REFERENCES niveis_status (codigo),
  titulo         VARCHAR(150) NOT NULL,
  descricao      TEXT,
  recomendacao   TEXT,                                     -- "recomendação da IA"
  janela_inicio  TIMESTAMPTZ,                              -- ex.: hoje 21h
  janela_fim     TIMESTAMPTZ,                              -- ex.: hoje 23h
  origem         VARCHAR(10) NOT NULL DEFAULT 'ia'
                 CHECK (origem IN ('ia', 'regra', 'servidor', 'cidadao')),
  confianca      NUMERIC(4,3) CHECK (confianca BETWEEN 0 AND 1),
  situacao       VARCHAR(15) NOT NULL DEFAULT 'aberto'
                 CHECK (situacao IN ('aberto', 'em_analise', 'acao_definida', 'resolvido', 'descartado')),
  criado_em      TIMESTAMPTZ NOT NULL DEFAULT now(),
  atualizado_em  TIMESTAMPTZ NOT NULL DEFAULT now(),
  encerrado_em   TIMESTAMPTZ,
  CONSTRAINT ck_alertas_alvo   CHECK (regiao_id IS NOT NULL OR local_id IS NOT NULL),
  CONSTRAINT ck_alertas_janela CHECK (janela_inicio IS NULL OR janela_fim IS NULL OR janela_fim > janela_inicio)
);

-- Ação preventiva definida pelo servidor, atribuída a uma equipe.
-- nota_antes / nota_depois permitem "acompanhar o resultado" da ação.
-- prioridade: 1 = alta · 2 = média · 3 = baixa.
CREATE TABLE acoes_preventivas (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  alerta_id       BIGINT       REFERENCES alertas (id) ON DELETE SET NULL,
  local_id        BIGINT       NOT NULL REFERENCES locais (id),
  categoria_id    SMALLINT     NOT NULL REFERENCES categorias_ocorrencia (id),
  equipe_id       INTEGER      REFERENCES equipes (id),
  responsavel_id  BIGINT       REFERENCES usuarios (id) ON DELETE SET NULL,
  titulo          VARCHAR(150) NOT NULL,
  descricao       TEXT,
  prioridade      SMALLINT     NOT NULL DEFAULT 2 CHECK (prioridade BETWEEN 1 AND 3),
  situacao        VARCHAR(15)  NOT NULL DEFAULT 'planejada'
                  CHECK (situacao IN ('planejada', 'em_execucao', 'concluida', 'cancelada')),
  prevista_para   TIMESTAMPTZ,
  iniciada_em     TIMESTAMPTZ,
  concluida_em    TIMESTAMPTZ,
  nota_antes      SMALLINT CHECK (nota_antes  BETWEEN 0 AND 100),
  nota_depois     SMALLINT CHECK (nota_depois BETWEEN 0 AND 100),
  resultado       TEXT,
  criado_em       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  atualizado_em   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT ck_acoes_periodo CHECK (concluida_em IS NULL OR iniciada_em IS NULL OR concluida_em >= iniciada_em)
);

-- =====================================================================
-- 8. FUNÇÕES DE NEGÓCIO
-- =====================================================================

-- Converte uma nota (0 a 100) no código do semáforo (estavel, atencao, prioridade).
CREATE FUNCTION fn_status_da_nota(p_nota INTEGER) RETURNS VARCHAR
LANGUAGE sql STABLE AS $$
  SELECT codigo
    FROM niveis_status
   WHERE p_nota BETWEEN nota_min AND nota_max
   ORDER BY gravidade
   LIMIT 1;
$$;

-- Média ponderada das notas dos fatores de um índice (usa fatores.peso).
CREATE FUNCTION fn_nota_ponderada(p_indice_id BIGINT) RETURNS SMALLINT
LANGUAGE sql STABLE AS $$
  SELECT ROUND(SUM(f.peso * i.nota) / NULLIF(SUM(f.peso), 0))::SMALLINT
    FROM indice_fatores i
    JOIN fatores f ON f.id = i.fator_id
   WHERE i.indice_id = p_indice_id
     AND f.ativo;
$$;

-- Recalcula e grava a nota de um índice a partir dos fatores cadastrados.
CREATE FUNCTION fn_recalcular_indice(p_indice_id BIGINT) RETURNS SMALLINT
LANGUAGE plpgsql AS $$
DECLARE
  v_nota SMALLINT;
BEGIN
  v_nota := fn_nota_ponderada(p_indice_id);
  IF v_nota IS NULL THEN
    RAISE EXCEPTION 'O índice % não possui fatores cadastrados', p_indice_id;
  END IF;
  UPDATE indices_preventivos
     SET nota = v_nota, calculado_em = now()
   WHERE id = p_indice_id;
  RETURN v_nota;
END;
$$;

-- Distância em metros entre dois pontos (fórmula de Haversine).
CREATE FUNCTION fn_distancia_metros(lat1 DOUBLE PRECISION, lng1 DOUBLE PRECISION,
                                    lat2 DOUBLE PRECISION, lng2 DOUBLE PRECISION)
RETURNS DOUBLE PRECISION
LANGUAGE sql IMMUTABLE AS $$
  SELECT 2 * 6371000 * asin(LEAST(1, sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
         )));
$$;

-- Local ativo mais próximo de uma coordenada (ex.: GPS do celular).
-- p_limite_metros NULL = sem limite de distância.
CREATE FUNCTION fn_local_mais_proximo(p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION,
                                      p_limite_metros INTEGER DEFAULT NULL)
RETURNS TABLE (local_id BIGINT, nome VARCHAR, distancia_m INTEGER)
LANGUAGE sql STABLE AS $$
  SELECT l.id, l.nome,
         round(fn_distancia_metros(p_lat, p_lng, l.latitude, l.longitude))::INTEGER
    FROM locais l
   WHERE l.ativo
     AND (p_limite_metros IS NULL
          OR fn_distancia_metros(p_lat, p_lng, l.latitude, l.longitude) <= p_limite_metros)
   ORDER BY fn_distancia_metros(p_lat, p_lng, l.latitude, l.longitude)
   LIMIT 1;
$$;

-- =====================================================================
-- 9. GATILHOS (TRIGGERS)
-- =====================================================================

-- 9.1 Mantém atualizado_em
CREATE TRIGGER trg_usuarios_atualizado  BEFORE UPDATE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();
CREATE TRIGGER trg_regioes_atualizado   BEFORE UPDATE ON regioes
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();
CREATE TRIGGER trg_locais_atualizado    BEFORE UPDATE ON locais
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();
CREATE TRIGGER trg_ocorrencias_atualizado BEFORE UPDATE ON ocorrencias
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();
CREATE TRIGGER trg_alertas_atualizado   BEFORE UPDATE ON alertas
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();
CREATE TRIGGER trg_acoes_atualizado     BEFORE UPDATE ON acoes_preventivas
  FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();

-- 9.2 Preenche resolvida_em quando a ocorrência é resolvida (e limpa se reabrir)
CREATE FUNCTION fn_ocorrencia_situacao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.situacao = 'resolvida' THEN
    NEW.resolvida_em := COALESCE(NEW.resolvida_em, now());
  ELSE
    NEW.resolvida_em := NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ocorrencias_situacao BEFORE UPDATE OF situacao ON ocorrencias
  FOR EACH ROW WHEN (OLD.situacao IS DISTINCT FROM NEW.situacao)
  EXECUTE FUNCTION fn_ocorrencia_situacao();

-- 9.3 Registra a linha do tempo da ocorrência.
-- Quem mudou a situação: o back-end informa o usuário na transação com
--   SELECT set_config('vigia.usuario_id', '<id do usuário>', true);
CREATE FUNCTION fn_ocorrencia_historico() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO ocorrencia_historico
      (ocorrencia_id, situacao_anterior, situacao_nova, responsavel_id, comentario, criado_em)
    VALUES
      (NEW.id, NULL, NEW.situacao, NEW.usuario_id, 'Ocorrência registrada', NEW.criado_em);
  ELSE
    INSERT INTO ocorrencia_historico
      (ocorrencia_id, situacao_anterior, situacao_nova, responsavel_id)
    VALUES
      (NEW.id, OLD.situacao, NEW.situacao,
       NULLIF(current_setting('vigia.usuario_id', true), '')::BIGINT);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_ocorrencias_hist_ins AFTER INSERT ON ocorrencias
  FOR EACH ROW EXECUTE FUNCTION fn_ocorrencia_historico();
CREATE TRIGGER trg_ocorrencias_hist_upd AFTER UPDATE OF situacao ON ocorrencias
  FOR EACH ROW WHEN (OLD.situacao IS DISTINCT FROM NEW.situacao)
  EXECUTE FUNCTION fn_ocorrencia_historico();

-- =====================================================================
-- 10. ÍNDICES DE DESEMPENHO
-- =====================================================================

CREATE INDEX ix_locais_regiao          ON locais (regiao_id);
CREATE INDEX ix_locais_tipo            ON locais (tipo_local_id);
CREATE INDEX ix_locais_coord           ON locais (latitude, longitude);
CREATE INDEX ix_eventos_local_inicio   ON eventos (local_id, inicio_em);
CREATE INDEX ix_indices_local_ref      ON indices_preventivos (local_id, referencia_em DESC);
CREATE INDEX ix_ocorrencias_local_data ON ocorrencias (local_id, criado_em DESC);
CREATE INDEX ix_ocorrencias_situacao   ON ocorrencias (situacao);
CREATE INDEX ix_ocorrencias_categoria  ON ocorrencias (categoria_id);
CREATE INDEX ix_ocorrencias_usuario    ON ocorrencias (usuario_id);
CREATE INDEX ix_anexos_ocorrencia      ON ocorrencia_anexos (ocorrencia_id);
CREATE INDEX ix_historico_ocorrencia   ON ocorrencia_historico (ocorrencia_id, criado_em);
CREATE INDEX ix_consultas_usuario      ON consultas_recomendacao (usuario_id, criado_em DESC);
CREATE INDEX ix_consultas_local        ON consultas_recomendacao (local_id);
CREATE INDEX ix_alertas_situacao       ON alertas (situacao);
CREATE INDEX ix_alertas_local          ON alertas (local_id);
CREATE INDEX ix_alertas_regiao         ON alertas (regiao_id);
CREATE INDEX ix_acoes_situacao         ON acoes_preventivas (situacao);
CREATE INDEX ix_acoes_local            ON acoes_preventivas (local_id);
CREATE INDEX ix_acoes_equipe           ON acoes_preventivas (equipe_id);

-- =====================================================================
-- 11. VIEWS (uma ou mais por tela do protótipo)
-- =====================================================================

-- Índice mais recente de cada local (ignora previsões e instantes futuros).
CREATE VIEW vw_indice_atual AS
SELECT DISTINCT ON (ip.local_id)
       ip.local_id,
       ip.id          AS indice_id,
       ip.nota,
       ip.origem,
       ip.referencia_em,
       ns.codigo      AS status_codigo,
       ns.nome        AS status_nome,
       ns.emoji       AS status_emoji,
       ns.cor_hex     AS status_cor
  FROM indices_preventivos ip
  JOIN niveis_status ns ON ip.nota BETWEEN ns.nota_min AND ns.nota_max
 WHERE ip.origem <> 'previsto'
   AND ip.referencia_em <= now()
 ORDER BY ip.local_id, ip.referencia_em DESC, ip.id DESC;

-- Mapa Preventivo: um marcador por local, já com nota e cor do semáforo.
CREATE VIEW vw_mapa_preventivo AS
SELECT l.id           AS local_id,
       l.nome,
       tl.codigo      AS tipo_codigo,
       tl.nome        AS tipo,
       r.id           AS regiao_id,
       r.nome         AS regiao,
       l.latitude,
       l.longitude,
       ia.nota,
       ia.status_codigo,
       ia.status_nome,
       ia.status_emoji,
       ia.status_cor,
       ia.referencia_em
  FROM locais l
  JOIN tipos_local tl ON tl.id = l.tipo_local_id
  JOIN regioes r      ON r.id  = l.regiao_id
  LEFT JOIN vw_indice_atual ia ON ia.local_id = l.id
 WHERE l.ativo;

-- Detalhes do local: fatores do índice atual com o rótulo da barra.
CREATE VIEW vw_local_fatores_atuais AS
SELECT ia.local_id,
       f.codigo  AS fator_codigo,
       f.nome    AS fator,
       f.ordem,
       f.exibir_no_detalhe,
       x.nota,
       x.nivel,
       fn.rotulo,
       x.valor_bruto
  FROM vw_indice_atual ia
  JOIN indice_fatores x ON x.indice_id = ia.indice_id
  JOIN fatores f        ON f.id = x.fator_id
  JOIN fator_niveis fn  ON fn.fator_id = x.fator_id AND fn.nivel = x.nivel;

-- Situação de cada região. O status segue o PIOR local da região
-- (abordagem preventiva); a média também é exibida. Para usar a média,
-- troque x.nota_minima por x.nota_media no JOIN com niveis_status.
CREATE VIEW vw_regiao_status AS
SELECT x.regiao_id,
       x.regiao,
       x.rpa,
       x.qtd_locais,
       x.nota_minima,
       x.nota_media,
       ns.codigo  AS status_codigo,
       ns.nome    AS status_nome,
       ns.emoji   AS status_emoji,
       ns.cor_hex AS status_cor
  FROM (
        SELECT r.id   AS regiao_id,
               r.nome AS regiao,
               r.rpa,
               COUNT(ia.local_id)            AS qtd_locais,
               MIN(ia.nota)                  AS nota_minima,
               ROUND(AVG(ia.nota))::SMALLINT AS nota_media
          FROM regioes r
          LEFT JOIN locais l           ON l.regiao_id = r.id AND l.ativo
          LEFT JOIN vw_indice_atual ia ON ia.local_id = l.id
         WHERE r.ativa
         GROUP BY r.id, r.nome, r.rpa
       ) x
  LEFT JOIN niveis_status ns ON x.nota_minima BETWEEN ns.nota_min AND ns.nota_max;

-- Painel do servidor: contadores do topo da tela.
CREATE VIEW vw_painel_servidor AS
SELECT (SELECT COUNT(*) FROM vw_regiao_status WHERE status_codigo = 'prioridade') AS regioes_prioridade,
       (SELECT COUNT(*) FROM vw_regiao_status WHERE status_codigo = 'atencao')    AS regioes_atencao,
       (SELECT COUNT(*) FROM vw_regiao_status WHERE status_codigo = 'estavel')    AS regioes_estaveis,
       (SELECT COUNT(*) FROM alertas
         WHERE situacao IN ('aberto', 'em_analise'))                              AS alertas_abertos,
       (SELECT COUNT(*) FROM ocorrencias
         WHERE situacao IN ('recebida', 'em_analise', 'encaminhada'))             AS ocorrencias_pendentes,
       (SELECT COUNT(*) FROM acoes_preventivas
         WHERE situacao IN ('planejada', 'em_execucao'))                          AS acoes_em_andamento;

-- "Onde a Prefeitura deveria agir primeiro?"
-- pontuacao_prioridade é uma heurística demonstrativa: quanto maior, mais urgente.
CREATE VIEW vw_prioridade_atuacao AS
SELECT l.id    AS local_id,
       l.nome  AS local_nome,
       r.nome  AS regiao,
       ia.nota,
       ia.status_codigo,
       ia.status_emoji,
       COALESCE(oc.pendentes, 0) AS ocorrencias_pendentes,
       COALESCE(al.abertos, 0)   AS alertas_abertos,
       (100 - ia.nota) + 5 * COALESCE(al.abertos, 0) + 2 * COALESCE(oc.pendentes, 0)
                                 AS pontuacao_prioridade
  FROM locais l
  JOIN regioes r          ON r.id = l.regiao_id
  JOIN vw_indice_atual ia ON ia.local_id = l.id
  LEFT JOIN (SELECT local_id, COUNT(*) AS pendentes
               FROM ocorrencias
              WHERE situacao IN ('recebida', 'em_analise', 'encaminhada')
              GROUP BY local_id) oc ON oc.local_id = l.id
  LEFT JOIN (SELECT local_id, COUNT(*) AS abertos
               FROM alertas
              WHERE local_id IS NOT NULL
                AND situacao IN ('aberto', 'em_analise')
              GROUP BY local_id) al ON al.local_id = l.id
 WHERE l.ativo;

-- Reincidência: mesma categoria de problema repetida no mesmo local nos últimos 30 dias.
CREATE VIEW vw_reincidencia_30d AS
SELECT o.local_id,
       o.categoria_id,
       COUNT(*) AS qtd_30d
  FROM ocorrencias o
 WHERE o.criado_em >= now() - INTERVAL '30 days'
   AND o.situacao <> 'descartada'
 GROUP BY o.local_id, o.categoria_id
HAVING COUNT(*) >= 2;

-- Histórico do local (ocorrências, alertas e ações) para "Analisar histórico".
CREATE VIEW vw_historico_local AS
SELECT o.local_id,
       'ocorrencia'::TEXT                      AS tipo_registro,
       o.id                                    AS registro_id,
       o.criado_em                             AS data_registro,
       (c.nome || ': ' || left(o.descricao, 80)) AS resumo,
       o.situacao::TEXT                        AS situacao
  FROM ocorrencias o
  JOIN categorias_ocorrencia c ON c.id = o.categoria_id
UNION ALL
SELECT a.local_id, 'alerta', a.id, a.criado_em, a.titulo, a.situacao
  FROM alertas a
 WHERE a.local_id IS NOT NULL
UNION ALL
SELECT p.local_id, 'acao', p.id, p.criado_em, p.titulo, p.situacao
  FROM acoes_preventivas p;

-- Pulso do Recife: nota de cada hora já com a cor do semáforo.
CREATE VIEW vw_pulso AS
SELECT ph.local_id,
       ph.dia_semana,
       ph.hora,
       ph.nota,
       ns.codigo  AS status_codigo,
       ns.nome    AS status_nome,
       ns.emoji   AS status_emoji,
       ns.cor_hex AS status_cor,
       ph.atencao_recomendada,
       ph.fonte
  FROM pulso_horario ph
  JOIN niveis_status ns ON ph.nota BETWEEN ns.nota_min AND ns.nota_max;

-- Janelas contínuas de atenção recomendada (ex.: 21h às 23h).
CREATE VIEW vw_pulso_janelas AS
SELECT local_id,
       dia_semana,
       MIN(hora) AS hora_inicio,
       MAX(hora) AS hora_fim
  FROM (
        SELECT local_id, dia_semana, hora,
               hora - ROW_NUMBER() OVER (PARTITION BY local_id, dia_semana ORDER BY hora) AS grupo
          FROM pulso_horario
         WHERE atencao_recomendada
       ) t
 GROUP BY local_id, dia_semana, grupo;

-- =====================================================================
-- 12. COMENTÁRIOS (dicionário de dados visível no pgAdmin/DBeaver)
-- =====================================================================

COMMENT ON TABLE niveis_status          IS 'Semáforo do Índice Preventivo (Estável, Atenção, Prioridade) e as faixas de nota de cada nível.';
COMMENT ON TABLE fatores                IS 'Fatores que compõem o Índice Preventivo, com peso relativo. Horário e dia da semana ficam no Pulso.';
COMMENT ON TABLE fator_niveis           IS 'Rótulos das barras de cada fator na tela de detalhes (ex.: Fluxo = Baixo, Moderado, Alto).';
COMMENT ON TABLE tipos_local            IS 'Tipos de espaço público: praça, parque, orla, centro histórico e ponto turístico.';
COMMENT ON TABLE perfis_passeio         IS 'Perfis de passeio escolhidos na tela Quero evitar.';
COMMENT ON TABLE orgaos                 IS 'Órgãos públicos que atendem ocorrências e alertas.';
COMMENT ON TABLE categorias_ocorrencia  IS 'Categorias da tela Comunicar problema; também classificam as ações preventivas.';
COMMENT ON TABLE equipes                IS 'Equipes de campo às quais as ações preventivas são atribuídas.';
COMMENT ON TABLE usuarios               IS 'Login único dos dois perfis: cidadão/turista e servidor público.';
COMMENT ON TABLE servidores             IS 'Dados funcionais dos usuários com perfil servidor.';
COMMENT ON TABLE regioes                IS 'Regiões de monitoramento exibidas no Mapa Preventivo e no painel do servidor.';
COMMENT ON TABLE locais                 IS 'Espaços públicos monitorados (praças, parques, orlas, centros históricos e pontos turísticos).';
COMMENT ON TABLE eventos                IS 'Eventos programados que alteram o fluxo de pessoas em um local.';
COMMENT ON TABLE indices_preventivos    IS 'Índice Preventivo (0 a 100) de cada local em um instante: atual, histórico ou previsto.';
COMMENT ON TABLE indice_fatores         IS 'Contribuição de cada fator para uma nota do índice (barras da tela de detalhes).';
COMMENT ON TABLE pulso_horario          IS 'Pulso do Recife: nota típica de cada local por dia da semana e hora.';
COMMENT ON TABLE ocorrencias            IS 'Problemas comunicados por cidadãos, servidores ou sistemas (tela Comunicar problema).';
COMMENT ON TABLE ocorrencia_anexos      IS 'Fotos enviadas com a ocorrência (somente o caminho; o arquivo fica fora do banco).';
COMMENT ON TABLE ocorrencia_historico   IS 'Linha do tempo das mudanças de situação da ocorrência (preenchida por gatilho).';
COMMENT ON TABLE consultas_recomendacao IS 'Histórico das consultas Quero evitar e Quero visitar e das recomendações geradas.';
COMMENT ON TABLE alertas                IS 'Alertas de atenção ou prioridade para regiões e locais, gerados pela análise (IA), por regras ou manualmente.';
COMMENT ON TABLE acoes_preventivas      IS 'Ações preventivas definidas pelo servidor, com equipe, prioridade e resultado.';

-- =====================================================================
-- 13. CARGA INICIAL (dados de referência)
-- Valores de que o sistema precisa para funcionar; não há dados fictícios.
-- Faixas do semáforo, pesos e rótulos podem ser ajustados conforme o
-- modelo de análise da AV2.
-- =====================================================================

-- Semáforo: faixas deduzidas dos exemplos da AV1
-- (92, 86 e 78 = Estável · 71 = Atenção · 43 = Prioridade).
INSERT INTO niveis_status (codigo, nome, emoji, cor_hex, nota_min, nota_max, gravidade) VALUES
  ('estavel',    'Estável',    '🟢', '#5DB88A', 75, 100, 1),
  ('atencao',    'Atenção',    '🟡', '#F0B03F', 50,  74, 2),
  ('prioridade', 'Prioridade', '🔴', '#E0584A',  0,  49, 3);

-- Pesos somam 100 (média ponderada). Ajuste conforme o modelo de análise da AV2.
INSERT INTO fatores (codigo, nome, descricao, peso, ordem, exibir_no_detalhe) VALUES
  ('FLUXO',          'Fluxo de pessoas',            'Movimentação de pessoas no local ao longo do dia.',                 15, 1, TRUE),
  ('ILUMINACAO',     'Iluminação',                  'Condição da iluminação pública do espaço.',                         20, 2, TRUE),
  ('INFRAESTRUTURA', 'Infraestrutura',              'Estado de calçadas, bancos, equipamentos e sinalização.',           15, 3, TRUE),
  ('OCORRENCIAS',    'Ocorrências',                 'Histórico de ocorrências registradas no local.',                    25, 4, TRUE),
  ('CHAMADOS',       'Relatos e chamados recentes', 'Chamados e informações enviados pelos cidadãos nos últimos dias.',  10, 5, FALSE),
  ('EVENTOS',        'Eventos programados',         'Eventos que concentram público no local.',                           5, 6, FALSE),
  ('REINCIDENCIA',   'Reincidência de problemas',   'Repetição do mesmo tipo de problema no mesmo local.',               10, 7, FALSE);

INSERT INTO fator_niveis (fator_id, nivel, rotulo)
SELECT f.id, v.nivel, v.rotulo
  FROM (VALUES
         ('FLUXO',          1, 'Baixo'),
         ('FLUXO',          2, 'Moderado'),
         ('FLUXO',          3, 'Alto'),
         ('ILUMINACAO',     1, 'Ruim'),
         ('ILUMINACAO',     2, 'Regular'),
         ('ILUMINACAO',     3, 'Boa'),
         ('INFRAESTRUTURA', 1, 'Ruim'),
         ('INFRAESTRUTURA', 2, 'Regular'),
         ('INFRAESTRUTURA', 3, 'Boa'),
         ('OCORRENCIAS',    1, 'Altas'),
         ('OCORRENCIAS',    2, 'Moderadas'),
         ('OCORRENCIAS',    3, 'Baixas'),
         ('CHAMADOS',       1, 'Muitos'),
         ('CHAMADOS',       2, 'Alguns'),
         ('CHAMADOS',       3, 'Poucos'),
         ('EVENTOS',        1, 'Grande evento'),
         ('EVENTOS',        2, 'Evento de médio porte'),
         ('EVENTOS',        3, 'Sem eventos'),
         ('REINCIDENCIA',   1, 'Alta'),
         ('REINCIDENCIA',   2, 'Moderada'),
         ('REINCIDENCIA',   3, 'Baixa')
       ) AS v(codigo, nivel, rotulo)
  JOIN fatores f ON f.codigo = v.codigo;

INSERT INTO tipos_local (codigo, nome) VALUES
  ('praca',            'Praça'),
  ('parque',           'Parque'),
  ('orla',             'Orla'),
  ('centro_historico', 'Centro histórico'),
  ('ponto_turistico',  'Ponto turístico');

-- Opções sugeridas (os PDFs só citam o campo "Perfil" da tela Quero evitar): ajuste conforme o protótipo.
INSERT INTO perfis_passeio (codigo, nome) VALUES
  ('sozinho', 'Sozinho(a)'),
  ('casal',   'Em casal'),
  ('familia', 'Família com crianças'),
  ('grupo',   'Grupo de amigos'),
  ('turista', 'Turista');

-- Categorias da tela Comunicar problema (AV1, Tela 7). O órgão responsável
-- fica vazio até os órgãos serem cadastrados; depois associe cada categoria:
--   UPDATE categorias_ocorrencia
--      SET orgao_id = (SELECT id FROM orgaos WHERE sigla = 'SIGLA')
--    WHERE codigo = 'seguranca';
INSERT INTO categorias_ocorrencia (codigo, nome, icone, ordem) VALUES
  ('seguranca',      'Segurança',      '🛡',  1),
  ('iluminacao',     'Iluminação',     '💡',  2),
  ('limpeza',        'Limpeza',        '🗑',  3),
  ('infraestrutura', 'Infraestrutura', '🚧',  4),
  ('aglomeracao',    'Aglomeração',    '👥',  5),
  ('outro',          'Outro',          '⚠️', 6);

-- Evolução opcional (AV2): para consultas geográficas avançadas, instale a
-- extensão PostGIS e troque latitude/longitude por colunas geography(Point, 4326).

COMMIT;
