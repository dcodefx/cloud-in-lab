# Policy Examples

Cilium Gateway API ve Network Policy referans örnekleri.

## Dizin Yapısı

```
extra-samples/policy-examples/
├── network/           # CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy örnekleri
├── gateway/           # Gateway API (Gateway / HTTPRoute) örnekleri
└── README.md
```

## Kullanım

Bu dizin salt referans amaçlıdır. Örnekleri production'a almadan önce namespace, label ve port değerlerini kendi ortamınıza göre düzenleyin.

## Policy Katmanları (3-Tier Architecture)

| Katman | Kaynak | Kapsam | Açıklama |
|--------|--------|--------|----------|
| Cluster-wide | CiliumClusterwideNetworkPolicy | Tüm cluster | Default deny, DNS, Gateway ingress |
| Namespace | CiliumNetworkPolicy | Tek namespace | Namespace'ler arası kısıtlama |
| Pod-level | CiliumNetworkPolicy | Seçili pod'lar | İnce taneli (FQDN, CIDR) kontroller |

## Label Stratejisi

| Label | Değer | Kullanım |
|-------|-------|----------|
| ingress-exposed | "true" | Gateway üzerinden dış dünyaya açılacak pod'lar |
| prometheus-scrape | "true" | Prometheus'un cluster genelinde scrape edeceği pod'lar |
| gateway-access | "true" | Gateway'e HTTPRoute bağlayacak namespace'ler |
