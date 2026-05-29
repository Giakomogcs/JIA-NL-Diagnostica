$front = "C:\Users\Administrador\Downloads\NL Diagnostica\nl-diagnostica-agent\front-nldiagnostica.html"
$dst   = "C:\Users\Administrador\Downloads\NL Diagnostica\nl-diagnostica-agent\workspaces\NLDiag-Front.json"
$enc   = New-Object System.Text.UTF8Encoding($false)

$html = [System.IO.File]::ReadAllText($front, $enc)

$workflow = [ordered]@{
    name        = "NLDiag-Front"
    nodes       = @(
        [ordered]@{
            parameters  = [ordered]@{
                httpMethod   = "GET"
                path         = "nldiag-app"
                responseMode = "responseNode"
                options      = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "App"
            type        = "n8n-nodes-base.webhook"
            typeVersion = 2
            position    = @(-220, 0)
            webhookId   = [Guid]::NewGuid().ToString()
        },
        [ordered]@{
            parameters  = [ordered]@{
                operation = "generateHtmlTemplate"
                html      = $html
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "HTML"
            type        = "n8n-nodes-base.html"
            typeVersion = 1.2
            position    = @(0, 0)
        },
        [ordered]@{
            parameters  = [ordered]@{
                respondWith  = "text"
                responseBody = "={{ `$json.html }}"
                options      = [ordered]@{
                    responseHeaders = [ordered]@{
                        entries = @(
                            [ordered]@{ name = "Content-Type"; value = "text/html; charset=utf-8" }
                        )
                    }
                }
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Respond to App"
            type        = "n8n-nodes-base.respondToWebhook"
            typeVersion = 1.1
            position    = @(220, 0)
        }
    )
    connections = [ordered]@{
        App = [ordered]@{
            main = @(,@(
                [ordered]@{ node = "HTML"; type = "main"; index = 0 }
            ))
        }
        HTML = [ordered]@{
            main = @(,@(
                [ordered]@{ node = "Respond to App"; type = "main"; index = 0 }
            ))
        }
    }
    settings    = [ordered]@{ executionOrder = "v1" }
}

$json = $workflow | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($dst, $json, $enc)

try {
    $check = [System.IO.File]::ReadAllText($dst, $enc) | ConvertFrom-Json
    "OK: NLDiag-Front.json valid. Nodes: $($check.nodes.Count). HTML bytes: $($html.Length). JSON size: $((Get-Item $dst).Length)"
} catch {
    "FAIL: $_"
}
