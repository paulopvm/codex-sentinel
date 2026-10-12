# Codex Sentinel

[English installation guide](docs/README.en.md) · [Contribuir](CONTRIBUTING.md) · [Downloads](https://github.com/paulopvm/codex-sentinel/releases) · [Licença MIT](LICENSE)

Projeto independente da comunidade, sem afiliação ou endosso da OpenAI.
Gratuito e aberto para uso, modificação e redistribuição sob a licença MIT.
A interface atual está em português brasileiro.

Aplicativo nativo para macOS que acompanha as cotas retornadas pelo Codex App Server, identifica conversas com falha confirmada por limite de uso e pode retomá-las quando o usuário habilita a função.

O Sentinel usa a interface oficial do App Server por `stdio`. Quando o Codex aberto já controla a conversa, encaminha a retomada pelo IPC local do desktop após confirmar estado inativo e ausência de solicitações pendentes. Uma conversa reservada mas descarregada é aberta pelo deep link do Codex antes de localizar seu controlador. Esse fallback usa um protocolo interno versionado: formatos incompatíveis bloqueiam o envio. Ele não lê o banco interno do Codex, não altera `config.toml`, não acessa arquivos de autenticação e não automatiza cliques ou teclado.

## Requisitos

- macOS 14 ou posterior.
- Swift 6.0 ou posterior e Swift Package Manager para compilar.
- CLI `codex` instalado e conectado à conta para consultar dados reais.
- Xcode completo é recomendado para desenvolvimento e depuração. Este projeto também pode ser compilado pelo Swift incluído no Command Line Tools.

## Instalar a partir do código

Instale o Codex CLI conforme o [guia oficial](https://developers.openai.com/codex/cli)
e autentique sua conta no CLI. Confira `codex --version` e `command -v codex`.
Para compilar, instale Xcode ou Command Line Tools (`xcode-select --install`) e
confira `swift --version`: é necessário Swift 6+. Os testes também exigem Python 3.

```sh
git clone https://github.com/paulopvm/codex-sentinel.git
cd codex-sentinel
```

A compilação local usa a arquitetura do seu Mac (Apple Silicon ou Intel).
Downloads prontos, quando disponíveis, ficam em [Releases](https://github.com/paulopvm/codex-sentinel/releases).
Confira a arquitetura e as notas de assinatura de cada versão. Apps sem assinatura
podem ser bloqueados: após conferir a origem, use **Ajustes do Sistema → Privacidade
e Segurança → Abrir Mesmo Assim**. Não é necessário desabilitar o Gatekeeper.

Na raiz do projeto:

```sh
./scripts/test-models.sh
./scripts/build-app.sh
open "dist/Codex Sentinel.app"
```

O conjunto de verificações usa dados fixos e um App Server falso; ele não inicia o CLI configurado nem acessa conversas da conta. A sequência de retomada só é exercitada contra IDs fictícios fornecidos pelo servidor de teste.

O script gera um aplicativo local em `dist/Codex Sentinel.app`; ele não o copia para a pasta Aplicativos. Para instalar em `~/Applications`:

```sh
./scripts/build-app.sh --install
open "$HOME/Applications/Codex Sentinel.app"
```

Para remover, encerre o aplicativo e apague `~/Applications/Codex Sentinel.app`. Para apagar também as preferências, tentativas e histórico locais, remova `~/Library/Application Support/Codex Sentinel` e a entrada de preferências `dev.codex.sentinel` em `defaults`.

## Primeiro uso

1. Abra **Configurações** e confira se o Sentinel encontrou `codex` no `PATH`. Se não encontrou, informe o caminho completo do executável.
2. Deixe o monitoramento ativo e use **Atualizar**. As cotas e conversas exibidas são as respostas reais do App Server; campos ausentes aparecem como indisponíveis.
3. A retomada automática começa desativada. Para usá-la, habilite a opção global em **Configurações**; ela se aplica a todos os chats elegíveis.
4. Notificações e abertura ao iniciar sessão são recursos opcionais. A autorização de notificação só é solicitada depois que você ativa a opção.

O Sentinel só considera um chat elegível quando o App Server informa uma falha de turno com `UsageLimitExceeded` (ou, sem código estruturado, a mensagem específica de limite de uso do Codex), não há estado ativo ou aprovação pendente, a janela de cotas foi retornada e todas as janelas conhecidas indicam disponibilidade. Limites de ferramentas ou serviços externos não tornam o chat elegível. Com a opção global ligada, qualquer chat que atender a esses critérios pode ser retomado. Mudanças no protocolo ou dados insuficientes deixam a retomada bloqueada.

## Dados locais

Preferências ficam em `UserDefaults` do app. Amostras de percentuais e o diário de tentativas ficam em `~/Library/Application Support/Codex Sentinel/`. O diário não guarda o conteúdo dos prompts nem das conversas. A retenção padrão é de 90 dias e pode ser ajustada.

O CLI escolhido é iniciado como `codex app-server --listen stdio://`. Quando `CODEX_HOME` é informado, ele é passado ao processo; caso contrário, o CLI usa seu padrão. O Sentinel não transmite esses dados para um servidor próprio. Consulte [SECURITY.md](SECURITY.md) para os limites e controles.

## Projeto de referência

O desenho foi analisado contra o projeto MIT [boyso/codex-reset](https://github.com/boyso/codex-reset/tree/10def8531262a15d5f00c73ce4264baf0e18290c), sem copiar código. O relatório [`REFERENCE_ANALYSIS.md`](REFERENCE_ANALYSIS.md) registra as escolhas e limitações. A integração segue a [documentação oficial do Codex App Server](https://developers.openai.com/codex/app-server).

## Limitações desta versão

- O Sentinel precisa que a versão local do CLI ofereça os métodos documentados de App Server usados pelo projeto.
- Com a retomada global ligada e as cotas disponíveis, a detecção pagina o catálogo do Codex e lê os detalhes de todos os chats não efêmeros, inclusive os mais antigos que o período de retenção do painel. O histórico exibido continua limitado à retenção configurada.
- Uma retomada aceita permanece registrada e é acompanhada por evento ou consulta ao App Server. Conflitos temporários de controle recebem novas tentativas com espera progressiva; não são abandonados após três tentativas. Antes de reenviar, o Sentinel confirma cotas, estado inativo e o mesmo turno limitado. Tentativas com um novo turno já identificado não são reenviadas.
- Cada retomada usa um processo separado do monitoramento. Ao receber o término do turno, o Sentinel encerra esse processo e confirma sua saída para liberar o controle da conversa ao Codex. A liberação ocorre mesmo sem um observador no painel e não interrompe outras retomadas. Se a resposta ao início for ambígua ou o acompanhamento expirar, uma consulta confirma o estado inativo antes de encerrar o processo; um timeout sozinho não interrompe um turno ativo.
- Os testes automatizados usam conversas fictícias e cobrem classificação, política de repetição, roteamento para o desktop e protocolo IPC. O IPC interno pode mudar entre versões do Codex; uma incompatibilidade aparece como erro e impede o envio.
- A compilação não é assinatura nem notarização da Apple; o macOS pode exigir que você confirme a abertura do app local.

## Solução de problemas

- **Codex não encontrado:** um app aberto pelo Finder pode receber um `PATH`
  diferente do Terminal. Copie o resultado de `command -v codex` para o campo
  de executável nas Configurações. Caminhos comuns: `/opt/homebrew/bin/codex`
  (Apple Silicon) e `/usr/local/bin/codex` (Intel).
- **Cotas indisponíveis:** confira login e versão do CLI no Terminal. Sem cotas
  confirmadas, a retomada fica bloqueada.
- **Conflito de controlador ou IPC incompatível:** confira versões do CLI e
  desktop, atualize o painel e revise a conversa original. Não apague sockets
  ou locks para forçar retomadas.
- **Sem ícone no Dock:** o Sentinel é um app de barra de menus. Fechar a janela
  mantém o monitoramento; use a opção de encerrar para sair.

Retomar inicia trabalho novo e consome o uso normal da conta. O Sentinel não
amplia nem contorna limites do Codex.

## Comunidade e contribuição

Issues e pull requests em português ou inglês são bem-vindos. Leia o
[guia de contribuição](CONTRIBUTING.md), o [código de conduta](CODE_OF_CONDUCT.md)
e a [política de segurança](SECURITY.md). A CI executa testes offline e build
em pull requests; revisão do mantenedor precede integração de contribuições.
Veja [oportunidades de melhoria](docs/ROADMAP.md) para ajudar.

Para gerar um ZIP universal (Apple Silicon + Intel), execute
`./scripts/package-release.sh`. O script inclui a licença e gera um checksum
SHA-256 em `dist/`. A assinatura é ad hoc, sem Developer ID ou notarização Apple.
