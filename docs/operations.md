# Operação e diagnóstico

Os comandos abaixo devem ser executados da raiz do repositório. O namespace
padrão é `zabbix`; os scripts de diagnóstico aceitam `NAMESPACE`.

## Conferir componentes

```bash
kubectl -n zabbix get pods,pvc
kubectl -n zabbix get events --sort-by=.lastTimestamp
```

O Helmfile usa `wait: false`. Uma release marcada como deployed não implica
que todos os pods estejam prontos; os verificadores aguardam o rollout.

| Script | Finalidade |
|---|---|
| `build-images.sh` | Build e importação das imagens locais no Kind |
| `rebuild-and-verify.sh` | Build, sync e verificação dos três sinais |
| `apply-and-verify-apm.sh` | Atualiza Collector/Alloy e verifica persistência |
| `verify-apm.sh` | Teste identificado de trace, métrica e log no ClickHouse |
| `verify-apm-api.sh` | Consulta APM pela API Zabbix, inclusive por Trace ID |
| `verify-apm-frontend.sh` | Verifica conexão pelo pod web e configuração global |
| `generate-apm-demo.sh` | Gera tráfego saudável, lento e com falhas |
| `backup-apm.py` | Exporta schemas e dados Native das tabelas de telemetria |
| `check-clickhouse-upgrade.sh` | Estado, eventos e logs do ClickHouse |
| `inspect-clickhouse-image.sh` | Diagnóstico isolado da imagem 26.8 Alpine |
| `recover-clickhouse-image.sh` | Recuperação do upgrade interrompido e preflight 25.8 |
| `upgrade-clickhouse-apm.sh` | Backup e atualização para o perfil 25.8 do lab |
| `fix-and-verify-apm-ui.sh` | Compatibilidade PHP 8.5 e diagnóstico da consulta APM |

## ClickHouse acessível, mas APM vazio

1. Execute `bash scripts/verify-apm.sh`: precisa persistir os três sinais.
2. Execute `bash scripts/verify-apm-frontend.sh`: verifique URL, database e
   autenticação da fonte global. O script oculta campos de senha.
3. Execute `bash scripts/verify-apm-api.sh`: testa a consulta do Zabbix.
4. Limpe filtros da interface, selecione a última hora e confirme o usuário.

O serviço de teste é `apm-smoke`; as APIs são `chaos-backend` e `dependency-api`.

## Falha de DNS após troca do ClickHouse

O Service do ClickHouse é headless. A configuração
`publishNotReadyAddresses: true` mantém seu DNS durante transições de readiness.
Após uma troca do pod, uma resposta DNS negativa pode permanecer em cache por
alguns segundos; o teste da API repete apenas esse erro por até 60 segundos.

## Compatibilidade de versão

O ClickHouse 24.8 não executa as subconsultas correlacionadas dos filtros de
Trace ID. A imagem 26.8.36.3 falhou com SIGILL no hardware local, inclusive
durante `clickhouse --version`, antes de abrir o volume de dados.
O perfil 25.8 foi usado como adaptação do laboratório e está abaixo do mínimo
oficial atualmente documentado para o Zabbix APM.

`recover-clickhouse-image.sh` contém um procedimento específico para o upgrade
26.8 que falhou antes de iniciar. Ele não é uma ferramenta geral de downgrade.
Não reutilize uma versão antiga do ClickHouse em um volume já aberto e
modificado por uma versão nova.

Em StatefulSets, reverter o template pode deixar um pod quebrado na revisão
anterior. O script compara as imagens e só recria o pod 26.8 específico quando
o template já foi restaurado ao 24.8. Não remove PVCs.

## Backup

```bash
python3 scripts/backup-apm.py
```

Cria uma pasta `zabbix-apm-backup-*` no diretório pessoal, com `SHOW CREATE
TABLE`, dados em Native comprimido e marcador `BACKUP_COMPLETE`. As tabelas
são copiadas individualmente enquanto a ingestão pode continuar; não é um
snapshot transacional do conjunto. Preserve a pasta fora do Git.

Para restaurar, use um banco de destino vazio, aplique os schemas respeitando
dependências de tabelas/views e importe os dados com `INSERT INTO ... FORMAT
Native`. Não importe o backup sobre tabelas com dados sem definir antes como
evitar duplicação. A restauração completa não foi automatizada neste projeto.

## PHP 8.5

O chart web inclui um init container que copia `ApmDbClickHouse.php` da mesma
imagem e remove apenas chamadas standalone de `curl_close`, obsoletas no PHP
8.5. O arquivo corrigido é montado no container web. O patch preserva a
reportagem de erros de consulta e pode ser desativado com
`web.apmCurlCloseCompat=false` quando a imagem upstream corrigir o problema.

## Credenciais e escopo

As senhas de exemplo são públicas e destinadas a este laboratório. Os scripts
da API usam `Admin` / `zabbix` por padrão. Credenciais customizadas precisam
estar disponíveis no ambiente do processo que realiza a consulta.

Manifests não incluem Ingress público nem TLS para a demonstração; os acessos
descritos usam port-forward. O chart MCP é um componente adicional de estudo
e não participa do pipeline APM.
