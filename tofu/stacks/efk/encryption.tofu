terraform {
  encryption {
    key_provider "pbkdf2" "homelab" {
      passphrase = file("${path.module}/../../secrets/encryption.key")
    }

    method "aes_gcm" "enc" {
      keys = key_provider.pbkdf2.homelab
    }

    state {
      method   = method.aes_gcm.enc
      enforced = true
    }

    plan {
      method = method.aes_gcm.enc
    }
  }
}
