# Caixa Forte API

API de pagamentos com livro-razão de dupla entrada. O objetivo é tratar dinheiro do jeito que sistemas financeiros tratam: nenhum saldo é editado direto, toda movimentação é um lançamento imutável, e a mesma requisição repetida nunca cobra duas vezes.

> **Status:** em andamento. A modelagem do domínio e o esquema do banco estão prontos; a API está sendo implementada.

## O problema

Um saldo guardado como um número que o sistema soma e subtrai tem três falhas clássicas:

1. **Requisição repetida.** O cliente não recebe a resposta por um timeout, tenta de novo e a transferência acontece duas vezes.
2. **Corrida no saldo.** Duas transferências simultâneas leem o mesmo saldo, as duas passam na validação e a conta fica negativa.
3. **Sem rastro.** Quando o saldo não bate, não há como reconstruir o que aconteceu.

## Como o Caixa Forte resolve

**Dupla entrada.** Cada transação gera pelo menos dois lançamentos: um débito em uma conta e um crédito em outra, com a soma sempre zero. O saldo de uma conta é a soma dos seus lançamentos. Lançamento não se edita nem se apaga; um estorno é uma transação nova no sentido contrário.

**Idempotência.** Toda requisição que move dinheiro exige o cabeçalho `Idempotency-Key`. A chave é gravada na mesma transação do banco que cria os lançamentos, com restrição de unicidade. Se a mesma chave chegar de novo com o mesmo corpo, a API devolve a resposta original; com corpo diferente, devolve `422`.

**Concorrência.** A conta debitada é travada com `SELECT ... FOR UPDATE` antes de conferir o saldo, sempre na mesma ordem (por id) para evitar deadlock. A tabela `contas` guarda um saldo materializado, atualizado na mesma transação dos lançamentos, para que a validação não precise somar o histórico inteiro.

**Eventos sem perda.** Cada transação grava um evento numa tabela de saída (padrão *outbox*) dentro da mesma transação. Um publicador lê essa tabela e envia para o Redis Streams. Se o envio falhar, o evento continua pendente e é reprocessado; os consumidores descartam eventos repetidos pelo id.

```
Cliente ──POST /transferencias (Idempotency-Key)──> API (Spring Boot)
                                                     │
                                  uma transação no PostgreSQL:
                                  ├─ grava a chave de idempotência
                                  ├─ trava as contas (FOR UPDATE)
                                  ├─ cria a transação e os lançamentos
                                  ├─ atualiza os saldos materializados
                                  └─ grava o evento na outbox
                                                     │
                       publicador ──lê a outbox──> Redis Streams ──> consumidores
```

## Modelo de dados

| Tabela | Papel |
|---|---|
| `contas` | Titular, moeda e saldo materializado (em centavos, `BIGINT`) |
| `transacoes` | Uma operação de negócio: transferência, depósito ou estorno |
| `lancamentos` | Débitos e créditos de cada transação; imutáveis |
| `chaves_idempotencia` | Chave, hash do corpo e resposta gravada |
| `outbox` | Eventos a publicar, com tentativas e último erro |

O esquema completo está em [`V1__esquema_inicial.sql`](src/main/resources/db/migration/V1__esquema_inicial.sql). Valores ficam em centavos inteiros para não sofrer com arredondamento de ponto flutuante. As regras mais importantes ficam no próprio banco: lançamento imutável por trigger, transação que não fecha em zero é recusada no commit, e uma transação só pode ser estornada uma vez.

## Endpoints planejados

| Método | Rota | O que faz |
|---|---|---|
| `POST` | `/contas` | Abre uma conta |
| `GET` | `/contas/{id}` | Saldo e dados da conta |
| `GET` | `/contas/{id}/extrato` | Lançamentos paginados por cursor |
| `POST` | `/transferencias` | Transfere entre contas (exige `Idempotency-Key`) |
| `POST` | `/transacoes/{id}/estorno` | Estorna uma transação (exige `Idempotency-Key`) |

## Stack

Java 21, Spring Boot 3, PostgreSQL 16, Flyway, Redis Streams, Testcontainers e Docker Compose.

## Etapas

- [x] Modelagem do domínio e regras de consistência
- [x] Esquema do banco com as restrições de integridade
- [ ] Abertura de conta e consulta de saldo
- [ ] Transferência com idempotência e trava pessimista
- [ ] Estorno
- [ ] Outbox e publicação no Redis Streams com reprocessamento
- [ ] Teste de concorrência: 1.000 transferências simultâneas sem saldo negativo e com a soma dos lançamentos igual a zero
- [ ] Docker Compose para subir tudo com um comando
