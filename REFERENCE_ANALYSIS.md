# Análise de referência — Codex Sentinel

> Registro histórico de decisões e diagnósticos. Alguns limites e observações
> foram substituídos pela atualização ao final do documento. Para instalação e
> comportamento atual, consulte README.md e SECURITY.md. Relatos específicos de
> conversas e ambiente pessoal foram removidos para publicação.

Análise realizada em 12 de outubro de 2026, antes da implementação. O repositório `boyso/codex-reset` foi consultado no commit [`10def8531262a15d5f00c73ce4264baf0e18290c`](https://github.com/boyso/codex-reset/tree/10def8531262a15d5f00c73ce4264baf0e18290c). A documentação do App Server foi consultada em [developers.openai.com/codex/app-server](https://developers.openai.com/codex/app-server).

## Como o Codex Reset funciona

O projeto é um executável Swift Package para macOS 14+, com painel de barra de menus. `AppModel` coordena consultas de uso, threads, histórico e retomadas. `AppServerManager` tenta primeiro o socket Unix local do controle remoto do Codex; se não estiver disponível, inicia outra instância de `codex app-server` em uma porta WebSocket local. O `AppServerClient` usa JSON-RPC para consultar `account/rateLimits/read`, ler/listar threads e enviar `thread/resume` seguido de `turn/start`.

A descoberta das conversas interrompidas é separada da API: `SQLiteReader` abre `thread_history_1.sqlite` e `state_5.sqlite` dentro de `CODEX_HOME`. Ele procura turnos com `status = 'failed'` e `error_json` contendo `usageLimitExceeded`, associa título e diretório de trabalho, e filtra threads de subagentes por metadados locais. A sugestão de horário de recuperação é extraída do texto de erro. Embora o README descreva os bancos como somente leitura, a implementação usa `SQLITE_OPEN_READWRITE` em `SQLiteReader.swift`.

As preferências são guardadas em `UserDefaults`; o histórico resumido de janelas também é serializado ali. O projeto fornece scripts para montar um `.app` e instalar um LaunchAgent. Ele também oferece uma alternativa de retomada por AppleScript e Acessibilidade: abre um deep link, ativa a janela, clica por coordenadas e envia texto via clipboard.

O código está sob MIT. Nenhum trecho de implementação do Codex Reset será copiado nesta primeira versão; portanto, não é necessário incluir o aviso MIT do projeto no binário. A referência e o commit ficam registrados aqui.

## Estratégias aproveitadas

- Aplicativo nativo e local, com painel de menu, monitoramento de uso e lista de threads.
- Uma opção global controla a retomada de todos os chats que satisfazem os critérios de segurança. A especificação inicial previa escolha por thread; esse requisito foi substituído depois pelo pedido do usuário por um controle único.
- App Server como canal de consulta e retomada, mantendo o `threadId` original.
- Registro local de observações e tentativas, sem guardar conteúdo das conversas.
- Separação entre limites de uso, descoberta de threads, persistência e coordenação de retomadas.

## Estratégias substituídas

- Usar o transporte documentado JSON-RPC sobre `stdio` de `codex app-server --listen stdio://`; não habilitar `remote_control`, gravar em `config.toml`, abrir sockets por conta própria ou depender do socket privado do desktop.
- Para classificar a interrupção, consultar o histórico da thread pelo App Server e exigir um erro que identifique `UsageLimitExceeded`. Não depender do esquema SQLite e dos nomes versionados de arquivos internos do Codex Reset.
- Se a API não confirmar o motivo da interrupção, o estado será desconhecido e a retomada automática será bloqueada.
- A retomada começa desligada e usa uma única opção global. Quando ativada, aplica-se a todos os chats elegíveis, sem autorização por conversa. Não haverá automação gráfica ou permissão de Acessibilidade.
- Persistir tentativas com uma chave estável por thread e evento de limite. Cada evento tem até três tentativas; depois de `turn/start` ambíguo, uma nova leitura precisa confirmar que o mesmo turno continua limitado e inativo antes da próxima tentativa.
- Não encerrar processos com `pkill`, não alterar preferências do Codex e não expor prompts ou credenciais em logs.

## Interfaces oficiais e detalhes internos

| Capacidade | Fonte e status |
| --- | --- |
| Transporte local do App Server, handshake `initialize`/`initialized` | Documentado oficialmente; JSON-RPC em linhas JSON pelo `stdio` é o transporte padrão. [Guia oficial](https://developers.openai.com/codex/app-server). |
| Limites e metadados de cota | `account/rateLimits/read`, documentado; inclui janelas, `usedPercent`, `resetsAt`, `rateLimitReachedType` e buckets quando retornados. [Registro de métodos e tipos](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L1341-L1345). |
| Listagem e leitura de conversas | `thread/list` e `thread/read`, documentados; `thread/list` fornece cursor e estado em execução. `thread/read` pode incluir turnos sem carregar ou retomar a thread. [Tipos de list/read](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L772-L861). |
| Classificação de erro de limite | A documentação de eventos de turno lista `UsageLimitExceeded` entre `codexErrorInfo` possíveis. A forma dos dados persistidos retornados com cada versão do Codex ainda precisa ser validada; formato inesperado deve resultar em estado desconhecido. |
| Retomada | `thread/resume` e `turn/start` são métodos documentados. `turn/start` inicia trabalho novo na thread e pode consumir a cota normal. Não existe chave de idempotência documentada para `turn/start`; o Sentinel precisa impedir reenvios em resultados ambíguos. [Tipos de resume/start](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L552-L562) · [turn/start](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs#L1057-L1062). |
| `thread/turns/list` | Documentado como experimental; não será requisito do caminho principal. |
| SQLite `state_5.sqlite`/`thread_history_1.sqlite`, `usageLimitExceeded` minúsculo e socket `app-server-control.sock` | Comportamentos observados no Codex Reset, dependentes de detalhes locais/versão. O código consulta bancos em modo leitura e escrita, apesar da descrição no README. Não serão usados no caminho principal. |
| `remote_control` no `config.toml` e AppleScript/Acessibilidade | Estratégias do Codex Reset, não necessárias ao transporte `stdio` escolhido. Não serão ativadas pelo Sentinel. |

## Riscos identificados e respostas

1. **A retomada executa trabalho e consome uso.** Começa desativada; quando o usuário ativa a opção global, todos os chats elegíveis podem ser retomados. Não há teste com retomada real.
2. **Concorrência com o Codex Desktop.** Uma instância `app-server` separada pode não refletir perfeitamente o estado em memória de outra instância. O Sentinel consulta `thread/list`/`thread/read`, recusa status ativo ou pendente de aprovação e trata conflito/resultado ambíguo como intervenção necessária. Não há fallback para cliques.
3. **Formato e catálogo variam por versão.** Os campos são decodificados de forma tolerante; não se presume que toda conta tenha janelas de cinco horas e semanal. Campos ausentes aparecem indisponíveis.
4. **Atualização do Codex pode mudar compatibilidade.** A integração usa o CLI local configurável e mensagens JSON-RPC documentadas; erros e métodos ausentes são apresentados sem alterar a configuração do Codex.
5. **Ambiente de compilação.** A disponibilidade do Swift e do SDK varia por Mac; confira os requisitos atuais no README. A validação de compilação é distinta de autenticação e testes funcionais com o Codex.

## Fontes

### Atualização após diagnóstico funcional — 12 de outubro de 2026

O pedido posterior de retomada com o desktop aberto substituiu a decisão inicial de usar apenas stdio e limitar cada evento a três tentativas. Uma recusa explícita de `thread/resume` por outro controlador agora permite consultar o IPC local versionado do desktop. Conversas reservadas mas descarregadas são abertas pelo deep link `codex://threads/<id>` antes da descoberta do controlador. O envio exige estado inativo, formato compatível e ausência de solicitações pendentes. Depois de uma resposta ambígua sem identificador, outra tentativa exige uma nova leitura confirmando o mesmo turno limitado e inativo; um novo turno identificado impede reenvios.

Em um diagnóstico local, uma retomada foi confirmada pelo desktop como um novo turno em execução. A leitura de uma instância CLI separada pode indicar `interrupted` durante esse trabalho; somente `completed` ou `failed` confirma seu término. Recusas anteriores ao envio são reavaliadas com espera, sem um teto permanente de tentativas. O protocolo IPC permanece um detalhe interno sujeito a mudanças de versão.

- [Codex Reset — README e código no commit analisado](https://github.com/boyso/codex-reset/tree/10def8531262a15d5f00c73ce4264baf0e18290c)
- [Codex App Server — documentação oficial](https://developers.openai.com/codex/app-server)
- [App Server: resposta de erros e valores de `codexErrorInfo`](https://developers.openai.com/codex/app-server#errors)
- [Registro de métodos do protocolo em `openai/codex`](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs)
