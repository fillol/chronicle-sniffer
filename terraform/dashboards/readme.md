1.  **Le risorse della dashboard (i widget) sono state create da Terraform.**
2.  **Cloud Monitoring sta tentando di eseguire le query MQL** (Monitoring Query Language) che abbiamo definito nel file JSON della dashboard.
3.  **La sintassi di una o più di quelle query MQL è errata** o contiene qualcosa che l'interprete MQL di Cloud Monitoring non capisce.

Questo è un problema *diverso* dal fatto che i log non arrivino o le metriche non si popolino. Qui è proprio la *definizione del grafico/widget* nella dashboard che ha un problema.

**Possibili Cause nell'MQL:**

Rivediamo le query MQL che abbiamo messo nel file `terraform/dashboards/main_operational_dashboard.json`. Gli errori più comuni sono:

1.  **Nomi di Metriche Errati:** `fetch logging.googleapis.com/user/sniffer_heartbeat_count` - il nome della metrica deve essere esatto.
2.  **Nomi di Risorse Errati:** `fetch cloud_run_revision` o `fetch pubsub_subscription` - questi dovrebbero essere corretti.
3.  **Nomi di Etichette Errati:** `metric.label.sniffer_id`, `resource.service_name`. Se un'etichetta non esiste sulla metrica o risorsa, la query può fallire o dare risultati vuoti.
4.  **Nomi delle Colonne Valore Errati nelle Aggregazioni:** Questa è la causa più probabile quando si lavora con metriche personalizzate. In `sum(value.sniffer_heartbeat_count)`, il `value.sniffer_heartbeat_count` potrebbe non essere il nome corretto della colonna che contiene il valore della metrica.
    *   Per metriche DELTA/INT64 (i nostri contatori), la colonna valore è spesso `value.int64_value` o semplicemente `value.count` se non c'è un `value_extractor`.
    *   Per metriche DELTA/DISTRIBUTION (la nostra `udm_events_generated_count`), la colonna valore da aggregare potrebbe essere `value.distribution_value.count` (per il numero di punti nella distribuzione) o `value.distribution_value.sum` (per la somma dei valori nella distribuzione).
5.  **Sintassi dell'Aggregazione:** La parte ` {aggregation_function: rate(sum(value.request_count))}` è una scorciatoia. A volte è meglio essere più espliciti: `| group_by [], sum(value.request_count) | every 1m | align rate()` (l'ordine esatto può variare).
6.  **Errori di Battitura o Caratteri Speciali Non Escapati** (anche se MQL è generalmente robusto).

**Azione di Debug - Usare Metrics Explorer per Costruire le Query MQL Corrette:**

Questo è il modo più affidabile per ottenere le query MQL giuste:

1.  **Apri Cloud Monitoring -> Metrics Explorer.**
2.  **Per ogni widget della tua dashboard che dà errore:**
    *   **Ricrea il grafico manualmente in Metrics Explorer:**
        *   Seleziona la metrica (es. `logging.googleapis.com/user/sniffer_heartbeat_count`).
        *   Applica i filtri che vuoi (es. `resource.type = global` - nota: in Metrics Explorer UI, puoi selezionare i filtri dai menu a tendina).
        *   Applica le aggregazioni (es. `sum`, `rate`).
        *   Applica i `group_by` (es. `metric.label.sniffer_id`, `metric.label.interface`).
    *   **Una volta che il grafico in Metrics Explorer mostra i dati come li vorresti (anche se sono zero per ora, l'importante è che la query sia valida):**
        *   C'è una tab o un pulsante etichettato **"MQL"** o **"</> QUERY EDITOR"** in alto a destra dell'interfaccia di Metrics Explorer. Cliccalo.
        *   Questo ti mostrerà la query MQL esatta che la UI di Metrics Explorer ha generato per il grafico che hai costruito. **Questa query è garantita essere sintatticamente corretta per l'API di Monitoring.**
3.  **Copia la Query MQL da Metrics Explorer.**
4.  **Incolla questa query MQL corretta nel campo `timeSeriesQueryLanguage` del widget corrispondente nel tuo file `terraform/dashboards/main_operational_dashboard.json`**.
    *   **Attenzione:** Quando incolli MQL in una stringa JSON, se l'MQL contiene doppi apici `"` (ad esempio per stringhe letterali all'interno dell'MQL), devi fare l'escape di questi doppi apici come `\"` nel JSON. Le newline `\n` vanno bene.

**Esempio di Processo per il Widget "Sniffer Heartbeats":**

1.  **In Metrics Explorer:**
    *   RESOURCE TYPE: `Logs-based Metric` -> `logging.googleapis.com/user/sniffer_heartbeat_count`
    *   FILTER: (opzionale per ora, aggiungilo dopo se necessario) `resource.type` `is one of` `global`, `gce_instance`, `k8s_container`
    *   GROUP BY: `metric.label.sniffer_id`, `metric.label.interface`
    *   AGGREGATION: `rate` (per vedere conteggi al minuto) e poi `sum` (per sommare se ci sono più serie per lo stesso sniffer_id/interface, anche se non dovrebbe con questo group by). O semplicemente `sum` e poi `rate`. Prova entrambe le combinazioni per vedere cosa produce il grafico migliore. Potresti iniziare con `sum` e poi `align rate(1m)`.
2.  **Passa alla tab MQL in Metrics Explorer.** Copia la query generata.
    Potrebbe essere qualcosa di simile a:
    ```mql
    fetch logging.googleapis.com/user/sniffer_heartbeat_count
    | filter
        (resource.type == 'gce_instance' ||
         resource.type == 'k8s_container' ||
         resource.type == 'global')
    | group_by 1m, [row_count: count_true(value.sniffer_heartbeat_count > 0)] // O un'aggregazione più specifica
    | every 1m
    | group_by [metric.label.sniffer_id, metric.label.interface],
        [value_sniffer_heartbeat_count_sum: sum(row_count)] // O sum(value.int64_value) se il valore è int64
    ```
    **Nota:** Il `value.sniffer_heartbeat_count` che avevo usato prima potrebbe essere sbagliato. Per le metriche `DELTA`/`INT64` create da log (che sono contatori), il campo valore effettivo in MQL potrebbe essere `value.int64_value` o `value.double_value`, oppure devi aggregare con `count_true()` o semplicemente `count()`. Metrics Explorer te lo dirà.

3.  **Aggiorna il JSON della dashboard:**
    ```json
    // ...
    "widgets": [
      {
        "title": "Sniffer Heartbeats (by Sniffer ID & Interface)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                // INCOLLA QUI LA QUERY MQL COPIATA DA METRICS EXPLORER
                // (ricorda di fare l'escape dei doppi apici se presenti nell'MQL)
                "timeSeriesQueryLanguage": "fetch logging.googleapis.com/user/sniffer_heartbeat_count\n| filter (resource.type == 'gce_instance' || resource.type == 'k8s_container' || resource.type == 'global')\n| align rate(1m)\n| group_by [metric.label.sniffer_id, metric.label.interface],\n    sum(value.int64_value)" // Esempio, verifica il nome esatto della colonna valore
              },
              "plotType": "LINE",
              "legendTemplate": "$${metric.label.sniffer_id} ($${metric.label.interface})"
            }
          ] // ...
    ```

**Ripeti questo processo per ogni widget che dà l'errore "errors parsing query".**

Questo è il modo più robusto per definire le query per la dashboard quando si usa Terraform.
È un po' iterativo, ma ti assicura che le query siano quelle che l'API di Monitoring si aspetta.

Dopo aver aggiornato il file JSON:
1.  `terraform plan -out=tfplan.out` (dovrebbe mostrare una modifica alla dashboard).
2.  `terraform apply tfplan.out`.
3.  Controlla la dashboard dopo qualche minuto.
