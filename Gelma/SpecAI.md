# SpecAI - Specifiche Progetto Quickemu Gelma

## Descrizione Progetto
Configurazione e avvio di macchine virtuali basate su Quickemu all'interno dell'ambiente di sviluppo.
Configurazione corrente: `ubuntu-26.04.conf`.

## Problema Riscontrato
L'esecuzione del comando:
```bash
quickemu --vm ubuntu-26.04.conf
```
Generava l'errore:
```
qemu-system-x86_64: -chardev spicevmc,id=usbredirchardev1,name=usbredir: 'spicevmc' is not a valid char driver name
```

### Causa Radice
1. Nella variabile d'ambiente `$PATH` dell'utente è presente `/opt/qemu/bin` prima dei percorsi di sistema (`/usr/bin`).
2. `/opt/qemu/bin/qemu-system-x86_64` è una versione personalizzata di QEMU (v11.1.50) compilata senza il supporto SPICE (`spice-protocol` / `spice-server`).
3. Su Linux, `quickemu` inserisce automaticamente i parametri `-chardev spicevmc,id=usbredirchardev...` per il reindirizzamento USB.
4. Non supportando SPICE, l'eseguibile in `/opt/qemu/bin` rifiuta l'argomento `-chardev spicevmc` arrestando l'avvio della VM.

## Soluzione Applicata
In `ubuntu-26.04.conf` è stato aggiunto l'override del PATH:
```bash
PATH="/usr/bin:${PATH}"
```
Dato che `quickemu` effettua il `source` del file di configurazione e subito dopo risolve il binario QEMU (`command -v qemu-system-x86_64`), l'eseguibile utilizzato diventa `/usr/bin/qemu-system-x86_64` (fornito dal pacchetto di sistema Ubuntu che include i moduli SPICE), consentendo l'avvio corretto della VM.
