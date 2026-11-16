# XIQI OS v1.0 (XIQI Core x86_64) — Corporação Engecema

Sistema Operacional corporativo ultraleve e independente, projetado para estações corporativas e servidores bare-metal de data center.

## Recursos Principais

- **Núcleo Independente (`XIQI Core x86_64`)**: Instalação direta em disco rígido/NVMe de data center (`setup-xiqi.sh --install-disk /dev/sdX`) ou em servidor dedicado (`setup-xiqi.sh --local`), com controlador de serviço nativo (`xiqictl` / `xiqios.service`).
- **Espaço de Trabalho Web Multiabas**: Barra de endereço editável, histórico por aba, detecção automática de restrições `X-Frame-Options` / `CSP` e carregamento via **Proxy XIQI** (`/api/proxy`) quando necessário.
- **Pesquisa Web & Modo IA (`XIQI IA`)**: Suporte a Google, DuckDuckGo e Bing na busca web e assistente inteligente via Gemini (`gemini-4-hydrogen`) com grounding de pesquisa no servidor.
- **Painel Administrativo (`/admin`)**: Gestão de usuários corporativos protegida por Chave Mestra.

## Execução

```bash
npm install
npm run dev
```

O servidor inicia na porta `3000` (`0.0.0.0:3000`).
