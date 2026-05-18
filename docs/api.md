# Using nisp as a library

The DSL exports its AST and emitter, so you can construct and emit Nix
programmatically from Racket.

## Basic usage

```racket
(require nisp)

(define expr
  (att
    (services.openssh.enable #t)
    (networking.firewall.allowedTCPPorts (lst 80 443))))

(displayln (emit expr 0))
```

Output:

```nix
{
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

## Validation

`nisp/validate` exposes the building blocks behind `nisp validate` —
walk a parsed source, extract option-path references, infer value
shape, check against any schema you provide. Bring your own schema
source; nisp doesn't care whether it came from NixOS, home-manager,
or somewhere else.
