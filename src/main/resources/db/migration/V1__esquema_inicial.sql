-- Caixa Forte: esquema inicial do livro-razão de dupla entrada.
-- Valores em centavos (BIGINT). Lançamentos são imutáveis.

CREATE TABLE contas (
    id               BIGSERIAL PRIMARY KEY,
    titular          VARCHAR(120) NOT NULL,
    moeda            CHAR(3)      NOT NULL DEFAULT 'BRL',
    saldo            BIGINT       NOT NULL DEFAULT 0,
    permite_negativo BOOLEAN      NOT NULL DEFAULT FALSE, -- contas internas, como o caixa de depósitos
    criada_em        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT saldo_nao_negativo CHECK (permite_negativo OR saldo >= 0)
);

CREATE TABLE transacoes (
    id          UUID PRIMARY KEY,
    tipo        VARCHAR(20) NOT NULL CHECK (tipo IN ('TRANSFERENCIA', 'DEPOSITO', 'ESTORNO')),
    estorno_de  UUID REFERENCES transacoes (id),
    descricao   VARCHAR(200),
    criada_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT estorno_aponta_origem CHECK ((tipo = 'ESTORNO') = (estorno_de IS NOT NULL))
);

-- Uma transação só pode ser estornada uma vez.
CREATE UNIQUE INDEX transacoes_um_estorno ON transacoes (estorno_de) WHERE estorno_de IS NOT NULL;

CREATE TABLE lancamentos (
    id            BIGSERIAL PRIMARY KEY,
    transacao_id  UUID   NOT NULL REFERENCES transacoes (id),
    conta_id      BIGINT NOT NULL REFERENCES contas (id),
    valor         BIGINT NOT NULL CHECK (valor <> 0), -- negativo = débito, positivo = crédito
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX lancamentos_extrato   ON lancamentos (conta_id, id DESC);
CREATE INDEX lancamentos_transacao ON lancamentos (transacao_id);

-- Lançamento não se altera nem se apaga: correção é sempre uma transação nova.
CREATE FUNCTION bloqueia_alteracao_lancamento() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'lançamentos são imutáveis';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER lancamentos_imutaveis
    BEFORE UPDATE OR DELETE ON lancamentos
    FOR EACH ROW EXECUTE FUNCTION bloqueia_alteracao_lancamento();

-- A soma dos lançamentos de cada transação tem que ser zero. A conferência é adiada
-- para o commit (DEFERRABLE), depois que todos os lançamentos da transação entraram.
CREATE FUNCTION confere_partidas_dobradas() RETURNS trigger AS $$
BEGIN
    IF (SELECT SUM(valor) FROM lancamentos WHERE transacao_id = NEW.transacao_id) <> 0 THEN
        RAISE EXCEPTION 'transação % não fecha em zero', NEW.transacao_id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER lancamentos_fecham_em_zero
    AFTER INSERT ON lancamentos
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION confere_partidas_dobradas();

CREATE TABLE chaves_idempotencia (
    chave         VARCHAR(80) PRIMARY KEY,
    hash_corpo    CHAR(64)    NOT NULL, -- SHA-256 do corpo da requisição
    status_http   SMALLINT    NOT NULL,
    resposta      JSONB       NOT NULL,
    transacao_id  UUID REFERENCES transacoes (id),
    criada_em     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE outbox (
    id            BIGSERIAL PRIMARY KEY,
    tipo_evento   VARCHAR(60) NOT NULL,
    payload       JSONB       NOT NULL,
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    publicado_em  TIMESTAMPTZ,
    tentativas    INT         NOT NULL DEFAULT 0,
    ultimo_erro   TEXT
);

-- O publicador só lê o que falta publicar.
CREATE INDEX outbox_pendentes ON outbox (id) WHERE publicado_em IS NULL;
