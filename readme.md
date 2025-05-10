# Pipeline Ibrida Wireshark-UDM su GCP
Questo progetto implementa una pipeline ibrida per la cattura, l'elaborazione e l'archiviazione di dati di traffico di rete in formato Unified Data Model (UDM) utilizzando Wireshark (tshark), Docker e Google Cloud Platform (GCP). 

La pipeline è progettata per catturare traffico di rete in un ambiente (es. on-premises o una VM dedicata), caricare i file di cattura grezzi su GCP, elaborarli in un formato strutturato (UDM) e archiviarli per analisi successive.

## Architettura
La pipeline è composta dai seguenti componenti principali:
- Sniffer: Un'applicazione containerizzata (Docker) basata su tshark che cattura il traffico di rete, ruota i file di cattura (.pcap), li carica in un bucket Google Cloud Storage e notifica un topic Pub/Sub.
- Google Cloud Storage (GCS): Utilizzato per archiviare i file .pcap grezzi in ingresso e i file .udm.json processati in uscita.
- Pub/Sub: Un servizio di messaggistica che riceve notifiche dallo Sniffer ogni volta che un nuovo file .pcap è disponibile.
- Cloud Run Processor: Un servizio serverless containerizzato (Docker) che si sottoscrive al topic Pub/Sub. Quando riceve una notifica, scarica il file .pcap corrispondente da GCS, lo converte in JSON usando tshark, trasforma il JSON in formato UDM usando uno script Python e carica il file .udm.json risultante in un altro bucket GCS.
- Terraform: Utilizzato per definire e deployare automaticamente tutta l'infrastruttura GCP necessaria (bucket GCS, topic Pub/Sub, servizio Cloud Run, Service Account e policy IAM).
- VM di Test (Opzionale): Una macchina virtuale su GCP creata da Terraform, preconfigurata con strumenti come tcpdump e tcpreplay per generare traffico di test.

## Il flusso di lavoro è:
Sniffer (Cattura) -> GCS (Storage Pcap) -> Pub/Sub (Notifica) -> Cloud Run Processor (Scarica Pcap, Converte in UDM) -> GCS (Storage UDM)

## Prerequisiti
Prima di iniziare, assicurati di avere installato e configurato quanto segue:
- Un account Google Cloud Platform e un progetto attivo.
- Google Cloud SDK (gcloud CLI) autenticato e configurato per il tuo progetto GCP.
- Terraform (versione >= 1.1.0).
- Docker.

## Struttura del Progetto
Il repository è organizzato come segue:

```plaintext
.
├── deploy.txt             # Istruzioni di deploy dettagliate (può essere integrato in questo README)
├── sniffer/
│   ├── Dockerfile         # Definizione del container Sniffer
│   ├── sniffer_entrypoint.sh # Script eseguito all'avvio del container Sniffer
│   └── gcp-key/           # **NON PUBBLICARE QUESTA DIRECTORY!** Contiene la chiave SA dello sniffer.
├── processor/
│   ├── Dockerfile         # Definizione del container Processor
│   ├── processor_app.py   # Applicazione Flask del processore Cloud Run
│   ├── json2udm_cloud.py  # Script di conversione da tshark JSON a UDM
│   └── requirements.txt   # Dipendenze Python per il processore
└── terraform/
    ├── main.tf            # Definizione principale dell'infrastruttura e IAM
    ├── variables.tf       # Variabili di input per la configurazione Terraform
    ├── outputs.tf         # Output utili dopo il deploy Terraform
    ├── provider.tf        # Configurazione del provider Google Cloud
    ├── terraform.tfvars.example # Esempio del file di configurazione delle variabili (da modificare)
    ├── terraform.tfvars   # **NON PUBBLICARE QUESTO FILE!** Contiene i valori specifici del tuo deploy.
    ├── .terraform/        # **NON PUBBLICARE QUESTA DIRECTORY!** Contiene i plugin Terraform scaricati.
    ├── terraform.tfstate* # **NON PUBBLICARE QUESTI FILE!** Contengono lo stato del tuo deploy.
    └── modules/           # Moduli Terraform riutilizzabili: ognuno con main.tf, variables.tf e output.tf
        ├── cloudrun_processor/
        ├── gcs_buckets/
        ├── pubsub_topic/
        └── test_generator_vm/
```

## Usage

```bash
# 1. Autentica il tuo account utente con gcloud
gcloud auth login

# 2. Imposta il progetto GCP predefinito
gcloud config set project gruppo-2

# 3. Crea le Application Default Credentials per Terraform e altre applicazioni
gcloud auth application-default login

# 4. Configura Docker per autenticarsi con Artifact Registry
gcloud auth configure-docker europe-west8-docker.pkg.dev
```

Dopo aver completato questi passaggi: `terraform init`, `terraform plan` e `terraform apply`