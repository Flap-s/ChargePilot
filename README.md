# ChargePilot

Une application originale pour prendre soin de la batterie des MacBook Apple Silicon : elle limite la charge, depuis la barre des menus, et la tient même quand l'app est fermée.

Une batterie lithium-ion vieillit plus vite quand elle reste longtemps pleine. ChargePilot arrête la charge à la limite choisie (80 % par défaut) tout en laissant le Mac fonctionner sur secteur.

## Fonctionnalités

- **Limite de charge** de 20 à 100 %, tenue par un petit assistant système, même app fermée.
- **Recharger** à 100 % une fois (la limite revient au débranchement), **Décharger** sur secteur jusqu'à la limite, **Calibrer** (décharge, charge complète, pause, retour à la limite).
- **Cycles** pour un Mac qui reste sur un dock : il tourne sur batterie jusqu'à 30 %, se recharge jusqu'à 85 %, et recommence jusqu'au débranchement.
- **Navigation** (laisser la charge redescendre avant de recharger), **protection thermique**, **décharge automatique**, options de **veille**.
- **LED MagSafe** (automatique, éteinte, verte, orange), modes **économie d'énergie** et **haute puissance**.
- **Planification** de tâches, **historique** et graphiques (charge, température, puissance, santé), **notifications**.
- Commande `chargepilot` et liens `chargepilot://…` pour Raccourcis.
- **Mises à jour** intégrées depuis les publications GitHub.

## Installation

1. Téléchargez `ChargePilot.zip` depuis la [dernière publication](../../releases/latest) et placez `ChargePilot.app` dans **Applications**.
2. L'app n'est pas notarisée par Apple : au premier lancement, faites un clic droit sur l'app › **Ouvrir**, ou autorisez-la dans Réglages Système › Confidentialité et sécurité.
3. Cliquez sur l'icône de batterie dans la barre des menus, puis sur **Installer l'assistant**. Votre mot de passe est demandé une fois : l'assistant est le service système qui pilote la charge.

Si un autre outil de limitation de charge est installé, quittez-le : deux outils qui pilotent la même batterie se contredisent.

Pour tout retirer : Réglages › Assistant › **Désinstaller**, puis supprimez l'app.

## Comment la charge est contrôlée

L'assistant (`/Library/PrivilegedHelperTools/app.chargepilot.helper`, lancé par launchd) choisit selon le Mac :

1. une clé SMC de suspension de charge (`CHTE`, ou `CH0B`/`CH0C` sur les firmwares plus anciens) ;
2. sinon, sur macOS 27 où Apple réserve ces clés, la **limite native de macOS** (80, 85, 90 ou 95 %), qui suspend la charge en restant sur secteur ;
3. pour les autres valeurs, la **coupure de l'adaptateur** (`CHIE`) sur une plage de 2 %, avec la limite native au palier supérieur comme garde-fou pendant la veille.

L'assistant n'accepte que l'app et la commande `chargepilot` (vérification de leur signature) et n'écrit que dans les clés SMC liées à la charge. En pause ou à la désinstallation, il rend la main à macOS et rétablit la limite native d'origine.

`chargepilot hardware '<json>'` permet de déclarer d'autres clés SMC pour un firmware inconnu (clés de charge uniquement).

## Commande

Installable dans `/usr/local/bin` depuis Réglages › Assistant.

```text
chargepilot status | json | limit 80 | topup | discharge 60 | calibrate | cycles 30 85 | cancel | pause | resume
chargepilot sailing on 5 | heat on 35 | led auto | lowpower on | smc read CHIE
```

Liens : `chargepilot://limit/80`, `chargepilot://topup`, `chargepilot://cycle`, `chargepilot://calibrate`, `chargepilot://pause`, `chargepilot://update`…

## Construire

Prérequis : macOS 15 ou plus récent, Xcode (Swift 6).

```bash
Scripts/build-app.sh   # build.noindex/ChargePilot.app et ChargePilot.zip
swift test
```

L'app est signée ad hoc avec des exigences épinglées aux identifiants (`app.chargepilot.ChargePilot`, `app.chargepilot.cli`, `app.chargepilot.helper`) ; définissez `CODESIGN_IDENTITY` pour signer avec un Developer ID. La signature se fait hors du dossier du projet, que la synchronisation iCloud peut modifier en cours de route.

## Mises à jour

ChargePilot vérifie les publications de son dépôt GitHub au démarrage puis toutes les 6 heures, ou à la demande dans Réglages › Mises à jour. Si une version plus récente existe, `ChargePilot.zip` est téléchargée, son identifiant, sa version et sa signature sont vérifiés, puis elle remplace l'app et la relance. L'assistant n'est réinstallé (avec le mot de passe administrateur) que si son code a changé : sa révision, `ChargePilotBuild.helperRevision`, est indépendante de la version de l'app.

Publier une version (le dépôt est lu depuis `git remote origin`) :

```bash
Scripts/release.sh 1.1.0 "Ce qui change"
```

## Remerciements

Le comportement des firmwares récents (clés SMC réservées sur macOS 27, limite native pilotable) a été établi grâce aux recherches publiées par les projets open source [batt](https://github.com/charlie0129/batt) et [battery-limit-macos27](https://github.com/ldubs9/battery-limit-macos27).
