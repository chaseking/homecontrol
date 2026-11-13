.PHONY: app run install backend setup snapshots
setup:      ; ./scripts/setup-backend.sh
app:        ; ./scripts/build-app.sh
run:        ; ./scripts/build-app.sh --open
install:    ; ./scripts/build-app.sh --install
backend:    ; backend/.venv/bin/python backend/server.py --port 8790 --config "$(HOME)/Library/Application Support/HomeControl/config.json" --env "$(HOME)/Library/Application Support/HomeControl/.env"
snapshots:  ; build/HomeControl.app/Contents/MacOS/HomeControl --snapshot build/snapshots && open build/snapshots
