"""drosera change-pipeline producer (#266).

Reads the GitHub Actions feed and the `live` events from Grafana Cloud Loki,
computes each repo's six stages once, serves the result as the schema-1
``pipeline.json`` and writes it back to Loki as ``change_pipeline_state``.
"""
