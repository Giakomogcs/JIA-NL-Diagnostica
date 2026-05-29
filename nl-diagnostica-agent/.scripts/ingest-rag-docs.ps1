# =============================================================
# Ingestão dos documentos de conhecimento (rag-docs) na base RAG.
# Envia cada .md para o webhook do workflow NLDiag-RAG (nldiag-rag-upsert),
# que faz chunk + embeddings + insert em nl_documents.
#
# Pré-requisitos:
#   - Workflow NLDiag-RAG importado e ATIVO no n8n.
#   - Credenciais NLDiag-DB, Azure OpenAI e Supabase account configuradas.
# Uso:
#   powershell -ExecutionPolicy Bypass -File .\.scripts\ingest-rag-docs.ps1 -N8nBase "https://seu-n8n/webhook"
# =============================================================
param(
  [string]$N8nBase = "http://localhost:5678/webhook",
  [string]$DocsDir = "$PSScriptRoot\..\rag-docs"
)

$enc = New-Object System.Text.UTF8Encoding($false)
$endpoint = "$($N8nBase.TrimEnd('/'))/nldiag-rag-upsert"

# title por file_id (apenas para metadados legíveis)
$titles = @{
  "EMPRESA-NLDIAG-01"      = "NL Diagnostica — Quem somos e o que fornecemos"
  "LINHA-HEMOSTASIA-01"    = "Linha Hemostasia — Produtos e finalidade de uso"
  "GLOSSARIO-LICITACOES-01"= "Glossário de Licitações Públicas"
  "REGRAS-PARTICIPACAO-01" = "Regras de Participação e Critérios de Decisão"
  "EFFECTI-INTEGRACAO-01"  = "Integração Effecti — Campos e sincronização"
  "EXEMPLOS-ANALISE-01"    = "Exemplos de Análise de Editais"
}

$files = Get-ChildItem -Path $DocsDir -Filter *.md | Where-Object { $_.Name -ne "README.md" } | Sort-Object Name
if (-not $files) { Write-Host "Nenhum .md encontrado em $DocsDir"; exit 1 }

foreach ($f in $files) {
  $text = [System.IO.File]::ReadAllText($f.FullName, $enc)

  # extrai o file_id da linha "**file_id:** XYZ"
  $fileId = $null
  if ($text -match '(?im)^\*\*file_id:\*\*\s*([A-Z0-9\-]+)') { $fileId = $Matches[1].Trim() }
  if (-not $fileId) { $fileId = [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToUpper() }

  $title = $titles[$fileId]
  if (-not $title) { $title = $f.BaseName }

  $payload = @{
    file_id      = $fileId
    title        = $title
    code         = $fileId
    mime_type    = "text/markdown"
    content_text = $text
  } | ConvertTo-Json -Depth 5

  try {
    $resp = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
    Write-Host "OK   $($f.Name)  ->  file_id=$fileId  ($($text.Length) chars)"
  } catch {
    Write-Host "FAIL $($f.Name)  ->  $($_.Exception.Message)"
  }
}

Write-Host ""
Write-Host "Concluído. Verifique no painel Documentos (admin) ou em nl_document_metadata."
