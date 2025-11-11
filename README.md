# 🏦 KipuBankV3

**KipuBankV3** es una evolución del contrato `KipuBankV2`, desarrollado como proyecto final del módulo DeFi.  
Su objetivo es simular el flujo completo de una aplicación bancaria descentralizada que acepta múltiples tokens, los convierte automáticamente a **USDC** mediante **Uniswap V2**, 
y mantiene un control de límites, roles y seguridad, reflejando las mejores prácticas del ecosistema Ethereum.

---
## ⚠️ Deployed en:

[Contrato](https://sepolia.etherscan.io/tx/0x6cc8d01bffb54757ad50f823aeefc609290735bb6cb6f00a48385742d62d23de)

## ✨ Características Principales

- **Depósitos generalizados:**  
  Acepta ETH, USDC y cualquier token ERC20 que tenga par directo con USDC en Uniswap V2.  
  Los tokens distintos a USDC se intercambian automáticamente por USDC al momento del depósito.

- **Conversión automática a USDC:**  
  Integra el router de **Uniswap V2** para realizar el swap dentro del contrato, acreditando el monto resultante en USDC al balance del usuario.

- **Control de límites (cap):**  
  El valor total en USDC no puede superar el límite máximo (`bankCap`).  
  También se restringen los retiros a un máximo definido (`withdrawLimit`).

- **Roles de seguridad:**  
  Basado en `AccessControl` de OpenZeppelin.  
  - `DEFAULT_ADMIN_ROLE`: control total.  
  - `OPERATOR_ROLE`: permite acciones de emergencia.  
  - `PAUSER_ROLE`: permite pausar o reanudar operaciones.

- **Protecciones de seguridad:**  
  - `ReentrancyGuard`  
  - Pausable  
  - Validaciones estrictas de parámetros  
  - Eventos para auditoría (`Deposit`, `Withdraw`, `TokenSwapped`)

- **Composición DeFi real:**  
  Compatible con Uniswap V2 (por ejemplo, router de Sepolia:  
  `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`).
  Aunque ahora uso el de Sepolia Testnet `0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008`

---

## ⚙️ Despliegue

### Desde Remix

1. Abrí el archivo `KipuBankV3.sol` en [Remix](https://remix.ethereum.org/).  
2. Seleccioná **Solidity Compiler** → versión `0.8.30`.  
3. Compilá el contrato.  
4. En la pestaña **Deploy & Run Transactions**, usá los siguientes parámetros del constructor:

_withdrawLimit: 10000e6 // límite de retiro en USDC
_bankCapUsd: 1000000e6 // cap total en USDC
_uniswapRouter: 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008   // Sepolia Testnet!!!
_usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

## 🧪 Testing

El proyecto fue preparado para **Foundry**, incluyendo un test suite completo (`KipuBankV3.t.sol`) que cubre:
- Depósitos y retiros.
- Pausa y control de roles.
- Validaciones de límites.
- Funciones administrativas y de emergencia.

Ejecutar los tests:
```bash
forge test -vv
```

## 📋 Notas de diseño

- La arquitectura prioriza simplicidad y seguridad, manteniendo la lógica base de KipuBankV2.
- Los swaps se realizan siempre a USDC para simplificar la contabilidad interna.
- La documentación y los eventos fueron diseñados para facilitar auditorías y la integración con un frontend.

 