# Microsoft Secure Boot CA certificates

Public certificates copied from Microsoft's `secureboot_objects` repository. They are committed so offline builds cannot silently change the trust set. `vngrd-image/lib/image.sh` verifies these digests before use.

| file | SHA-256 | source |
| --- | --- | --- |
| `microsoft-uefi-ca-2023.der` | `f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901` | `PreSignedObjects/DB/Certificates/microsoft uefi ca 2023.der` |
| `microsoft-option-rom-uefi-ca-2023.der` | `e5be3e64c6e66a281457ecdece0d6d0787577aad2a3a0144262c10c14ba8d8f1` | `PreSignedObjects/DB/Certificates/microsoft option rom uefi ca 2023.der` |

Both expire in 2038.

Microsoft UEFI CA 2011 is deliberately excluded. Add it only for a specific option ROM, and document the exception.

These certificates go only into **db**, never KEK or PK. Microsoft can sign components this machine loads, but cannot update db or replace the platform key.
