# Contribuindo / Contributing

Contribuições em português e inglês são bem-vindas: correções, documentação,
traduções, acessibilidade e relatos de compatibilidade em outros Macs.
Não é preciso pedir permissão para abrir uma issue ou pull request.

## Desenvolvimento

1. Faça um fork e clone seu fork.
2. Crie uma branch: `git switch -c fix/minha-correcao`.
3. Use macOS 14+, Swift 6+ e Python 3 para os testes. Confira `swift --version`
   e `python3 --version`. Não há dependências Swift externas.
4. Execute `./scripts/test-models.sh` e `./scripts/build-app.sh`.
5. Abra `dist/Codex Sentinel.app` e verifique a interface quando sua alteração
   envolver UI. Mantenha a retomada automática desligada durante testes manuais.
6. Abra um pull request para `main`, descrevendo problema, solução e validação.

Os testes usam servidores falsos e IDs fictícios; não exigem login ou conta Codex.
`swift test` não executa esta suíte: use o script acima. Não teste retomadas em
conversas reais de outras pessoas. CI compila e executa a suíte em macOS.

## Mapa do código

| Arquivo | Responsabilidade |
| --- | --- |
| `Models.swift` | Decodificação, classificação, cotas e política de repetição |
| `AppServerClient.swift` | JSON-RPC, processos e retomada via App Server |
| `DesktopIPCClient.swift` | Fallback interno versionado do desktop |
| `SentinelModel.swift` | Monitoramento, preferências e persistência |
| `CodexSentinelApp.swift` | Interface SwiftUI e barra de menus |
| `Tests/` | Verificações e fixtures offline |
| `scripts/` | Build, instalação local e testes |

## Critérios de revisão

- Diffs pequenos, uma intenção por PR e testes para mudanças de comportamento.
- Preserve processamento local, ausência de telemetria e retomada desligada por padrão.
- Dados ausentes nunca devem virar disponibilidade de cota presumida.
- Não enfraqueça os bloqueios para turno ativo, aprovação pendente ou resultado ambíguo.
- Evite novas dependências; proponha e justifique antes de introduzi-las.
- Não publique tokens, prompts, títulos, IDs ou diretórios pessoais em fixtures/logs.
- Separe testes offline, compilação, verificação da interface e testes reais na descrição.
- Protocolos internos devem falhar com segurança quando incompatíveis.

## Commits

Use uma primeira linha curta explicando por que a alteração é necessária.
Quando útil, acrescente trailers como `Constraint:`, `Rejected:`, `Confidence:`,
`Scope-risk:`, `Directive:`, `Tested:` e `Not-tested:`. Exemplo:

```text
Keep unavailable quota from triggering a continuation

Confidence: high
Scope-risk: narrow
Tested: offline model checks
Not-tested: live account continuation
```

## English quick guide

Fork the repository, create a branch, make a focused change and submit a PR to
`main`. Run `./scripts/test-models.sh` and `./scripts/build-app.sh` on macOS with
Swift 6+ and Python 3. The tests use fake servers and never require a Codex login.
Portuguese and English issues/PRs are welcome. Preserve local processing,
opt-in continuation and all concurrency/quota guards. Describe what you tested
and what remains untested. See [SECURITY.md](SECURITY.md) for private reports and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.

Contribuições são recebidas sob a [licença MIT](LICENSE) do projeto.
