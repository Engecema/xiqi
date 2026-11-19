# XIQI OS v1.0 (XIQI OS Core x86_64) — Corporação Engecema

Sistema Operacional corporativo ultraleve e independente, projetado para estações corporativas e servidores bare-metal de data center.

## Recursos Principais

- **Núcleo Independente (`XIQI OS Core x86_64`)**: Instalação direta em disco rígido/NVMe de data center (`setup-xiqi.sh --install-disk /dev/sdX`) ou em servidor dedicado (`setup-xiqi.sh --local`), com controlador de serviço nativo (`xiqictl`, `xiqios`, `xiqi-display`).
- **Boot Gráfico Direto e Neutro**: Usuário de sistema neutro `xiqi`, sessão direta via `startx` + `xfwm4` + `xiqi-browser.py` em tela cheia (`/home/xiqi/.xinitrc` e serviço `/etc/init.d/xiqi-display`), abrindo diretamente em `http://127.0.0.1:3000` sem tela de login prévia do SO.
- **Espaço de Trabalho Web Multiabas**: Barra de endereço editável, histórico por aba, detecção automática de restrições `X-Frame-Options` / `CSP` e carregamento via **Proxy XIQI** (`/api/proxy`) quando necessário.
- **Pesquisa Web & Modo XIQI AI (`XIQI AI`)**: Suporte a Pesquisa XIQI, DuckDuckGo e Bing na busca web e assistente inteligente (`XIQI AI`) com grounding de pesquisa no servidor via `XIQI_AI_KEY`.
- **Painel Administrativo (`/admin`)**: Gestão de usuários corporativos protegida por Chave Mestra.

## Execução

```bash
npm install
XIQI_AI_KEY=sua_chave_xiqi_ai npm run dev
```

O servidor inicia na porta `3000` (`0.0.0.0:3000`).
