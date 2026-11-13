.PHONY: app run backend setup snapshots
setup:      ; ./scripts/setup-backend.sh
app:        ; ./scripts/build-app.sh
run:        ; ./scripts/build-app.sh --open
backend:    ; backend/.venv/bin/python backend/server.py --port 8790
snapshots:  ; build/HomeControl.app/Contents/MacOS/HomeControl --snapshot build/snapshots && open build/snapshots
