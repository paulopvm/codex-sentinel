# Segurança e privacidade

## Limites de confiança

- O Sentinel inicia o executável Codex configurado como processo filho e conversa pelo `stdin`/`stdout` do App Server.
- O Codex App Server pode acessar dados e serviços da conta autorizada no CLI. O Sentinel não lê nem copia credenciais, tokens ou arquivos de autenticação.
- Os títulos, IDs, diretórios e estados das conversas passam pela memória do Sentinel para exibição e classificação.
- O Sentinel pode conectar ao socket Unix local `CODEX_HOME/ipc/ipc.sock` para encaminhar uma retomada ao desktop que já controla a conversa. Valida proprietário e versão do protocolo, exige estado inativo e nenhuma solicitação pendente. Não abre portas de rede, não ativa `remote_control`, não modifica `config.toml`, não consulta SQLite privado e não pede Acessibilidade, Gravação de Tela ou Automação.

## Retomada

- A opção global fica desligada por padrão. Quando ligada, aplica-se a todos os chats elegíveis, sem autorizações individuais.
- Só são elegíveis falhas identificadas como `UsageLimitExceeded`. Estado ativo, entrada pendente, aprovação, erro de outra natureza, cotas ausentes ou formato inesperado bloqueiam a retomada.
- O Sentinel grava um registro local antes de chamar `thread/resume` e `turn/start`. Conflitos temporários recebem repetição com espera progressiva. Uma resposta ambígua sem identificador do novo turno só pode ser seguida de nova tentativa se uma leitura atual confirmar que o mesmo turno continua limitado e inativo. Um turno novo já identificado impede reenvios.
- O fallback IPC só ocorre após recusa explícita de `thread/resume` por outro controlador; nunca após um `turn/start` de resultado incerto. O protocolo interno do desktop é versionado e uma incompatibilidade impede o envio.
- O cliente de monitoramento só lê dados. Cada retomada direta tem um processo próprio, encerrado após conclusão, falha ou interrupção confirmada; desligar ou reconectar o monitoramento não encerra uma retomada em curso. Respostas ambíguas mantêm o processo até uma leitura confirmar inatividade, sem reenviar o turno.
- O Sentinel não aprova solicitações, não altera planos e não garante que o texto enviado corresponda ao estado atual da tarefa. Revise as conversas retomadas.

## Notificações

Notificações são opcionais e podem incluir o título da conversa retomada.
Esse título pode aparecer nas prévias da Central de Notificações e na tela
bloqueada, conforme os ajustes do macOS. Desative prévias nos ajustes de
Notificações ou mantenha as notificações do Sentinel desligadas se necessário.

## Persistência

- O histórico local contém horário, nomes das janelas e percentuais de uso.
- O diário contém ID da conversa, ID do turno limitado, ID do turno iniciado quando conhecido, estado e horário da tentativa. Não inclui conteúdo de conversa ou prompts.
- Preferências ficam no domínio `dev.codex.sentinel` de `UserDefaults`.
- A retenção configurada remove amostras antigas; o diário de tentativas é conservado para evitar reenvio de eventos já tratados.

## Relato de vulnerabilidade

Use [Report a vulnerability](https://github.com/paulopvm/codex-sentinel/security/advisories/new)
para relatar uma vulnerabilidade em privado. Não abra uma issue pública com
exploit ou dados sensíveis. A linha 0.1.x recebe correções em melhor esforço;
não há auditoria de segurança independente nem prazo de resposta garantido.

Private vulnerability reports are welcome in Portuguese or English via the link
above. Do not include credentials or private conversation data.

Não inclua tokens, transcrições ou arquivos de autenticação em um relato. Informe a versão do Sentinel, macOS, versão do CLI e passos mínimos de reprodução.
