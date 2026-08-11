# Domain policy packs

Load **baseline first**, then one domain pack. None of these flip `enforcement_mode`.

```bash
psql "$DATABASE_URL" -f examples/packs/00-baseline.sql
psql "$DATABASE_URL" -f examples/packs/analytics.sql
```

Full catalog and customization: [`doc/packs.md`](../../doc/packs.md)  
Onboarding: [`docs/onboarding/README.md`](../../docs/onboarding/README.md)

**PEP contract:** if a pack mentions `unset` or `approved=false`, your middleware must send those sentinels when the real value is missing (`examples/integrations/evaluate_middleware.py`).
