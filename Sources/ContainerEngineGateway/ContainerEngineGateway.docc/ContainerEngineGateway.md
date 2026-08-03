# ``ContainerEngineGateway``

Route Docker-compatible Engine HTTP requests to one explicitly selected runtime provider.

## Overview

The container Engine package separates wire transport, route matching, provider identity, provider sessions, logging projections, and Unix HTTP serving into independent Swift libraries. `ContainerEngineGateway` is the fail-closed dispatch boundary: it accepts only routes declared by the generated Engine API ledger and advertised by the selected provider.

Use the modules in this package to build a runtime provider without importing Compose policy, Dev Container policy, or Apple Container implementation types into the Engine transport layer.

The production path is one public `ContainerUnixHTTPServer`, one `ContainerEngineGatewayResponder`, and one private `ContainerEngineProviderSessionServer`. Raw hijack and WebSocket responses retain distinct identities across the provider boundary; Docker-compatible WebSocket handshake validation and RFC 6455 framing occur only on the public Unix socket, with binary messages carrying the provider's exact unframed bytes. Duplex input is split into bounded provider frames and relayed in exact write/EOF order while output remains concurrent.

## Package modules

- [ContainerEngineWire](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerenginewire/)
- [ContainerEngineRouter](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerenginerouter/)
- [ContainerEngineRuntimeSPI](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerengineruntimespi/)
- [ContainerEngineProviderSession](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerengineprovidersession/)
- [ContainerEngineLogging](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerenginelogging/)
- [ContainerUnixHTTPServer](https://stephenlclarke.github.io/api/container-engine-api/documentation/containerunixhttpserver/)

## Topics

### Gateway dispatch

- ``ContainerEngineGatewayResponder``
