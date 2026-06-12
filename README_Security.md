# Vitals · Security — Plugin Roblox Studio

> Anciennement « Remote Security Auditor ». Fait partie de la suite **Vitals** (Security · Memory · Performance).

Un plugin qui **audite automatiquement la sécurité de tes RemoteEvents / RemoteFunctions**.

## Le problème qu'il résout

Le problème n°1 de tout l'écosystème Roblox : les **exploiters** firent tes remotes avec
des arguments arbitraires pour voler de la monnaie, infliger des dégâts, dupliquer des
objets, se téléporter, etc. La règle d'or « ne jamais faire confiance au client » est
connue de tous… mais **aucun outil gratuit ne te dit OÙ ton jeu est vulnérable**. Tout se
fait à la main, à l'œil, script par script.

Ce plugin scanne le code source de **tous tes scripts**, retrouve chaque handler serveur
(`OnServerEvent` / `OnServerInvoke`) et applique un moteur de règles pour repérer les
patterns dangereux. Tu obtiens un **rapport clique‑pour‑ouvrir** : sévérité, script,
numéro de ligne, et un **fix suggéré** pour chaque alerte.

L'analyse est **100 % statique** — elle ne lance pas le jeu, donc tu peux l'utiliser à
tout moment pendant le développement.

Deux fonctions le rendent vraiment utile :

- **Score de sécurité /100** en haut du panneau, avec jauge colorée et verdict
  (*Solide / Correct / Fragile / À risque*). Il remonte à mesure que tu corriges — parfait
  pour une démo ou une vidéo.
- **Quick-fix** sur chaque alerte corrigible : un bouton qui **insère directement le
  squelette de validation** dans ton script (garde `typeof`, ou anti-spam par joueur).
  L'insertion passe par `ChangeHistoryService`, donc **annulable avec Ctrl+Z**.

## Installation

1. Ouvre **Roblox Studio**.
2. Dans une fenêtre de script vide (par ex. un `Script` temporaire dans
   `ServerScriptService`), colle tout le contenu de `RemoteSecurityAuditor.luau`.
3. Dans l'Explorer, **clic droit sur ce script → « Save as Local Plugin… »**
   (Enregistrer comme plugin local).
4. Valide. Le plugin apparaît dans l'onglet **Plugins**, barre d'outils **Vitals**, bouton
   **Security**.
5. Tu peux ensuite supprimer le script temporaire : le plugin est installé séparément.

> La première fois que le plugin lit le code de tes scripts, Studio te demande
> d'autoriser la permission **« Injection de script »** (Script Injection).
> Accepte‑la : le plugin a besoin de lire `Source` pour analyser. Il **ne modifie jamais**
> ton code, il ne fait que le lire.

## Utilisation

1. Clique sur **Security** pour ouvrir le panneau (dock à droite).
2. Clique sur **« Lancer l'audit de sécurité »**.
3. Lis le **score /100** en haut, puis parcours les alertes, filtre par sévérité, et
   **clique une carte** pour ouvrir directement le script à la ligne concernée.
4. Sur une alerte corrigible, clique **🔧 Insérer la validation** (ou *Insérer un
   anti-spam*) : le plugin ajoute le garde dans ton code et relance l'audit — le score
   remonte. Si le résultat ne te convient pas, **Ctrl+Z**.

### Le score /100

Le score part de 100 et retire des points par alerte selon la sévérité (critique −25,
élevé −12, moyen −5, faible −2). En dessous de 35 c'est « À risque », au‑dessus de 85
« Solide ». C'est un indicateur de progression, pas une garantie.

### Le quick-fix

Pour les alertes R2/R3/R5, il insère un garde de type au début du handler :
`if typeof(arg) ~= "number" then return end` (à ajuster au type réel — un `TODO` est
laissé). Pour R4, il insère un cooldown anti-spam par joueur (0,5 s) et la table associée.
C'est un **point de départ sûr**, pas une validation métier complète : relis toujours le
code inséré.

## Les règles

| Code | Sévérité | Ce que ça détecte |
|------|----------|-------------------|
| **R1** | Critique | Un `OnServerEvent`/`OnServerInvoke` dans un **LocalScript** — il ne s'exécute jamais côté serveur (bug, ou logique critique côté client = contournable). |
| **R2** | Critique | Un **argument client non validé** utilisé directement sur de la monnaie, des stats, une position, ou des **DataStores**. C'est la faille classique de duplication / triche. |
| **R3** | Moyen | Un **argument client utilisé sans aucune validation** de type ou de plage (même sans sink évident). Défense en profondeur. |
| **R4** | Moyen | **Aucun rate‑limit / debounce** détecté : le remote peut être spammé (surcharge serveur, duplication). |
| **R5** | Élevé | Le serveur **agit sur une Instance fournie par le client** (`:Destroy`, `.Parent`, etc.) sans vérifier son type ni la propriété. |
| **R6** | Faible | Une `RemoteFunction` (`OnServerInvoke`) **sans `return`** clair : risque de blocage du client appelant. |
| **R7** | Info | Un **remote sans handler serveur** détecté : surface d'attaque oubliée ou remote mort. |
| **R8** | Info | Handler connecté via une **fonction nommée** (non inline) : l'analyse statique ne peut pas vérifier son corps → **revue manuelle**. |
| **R9** | Info | Un **`UnreliableRemoteEvent`** : à ne jamais utiliser pour de l'état de jeu (messages perdables / désordonnés). |

## Limites (à lire)

C'est une **analyse heuristique**, pas une preuve formelle de sécurité. À utiliser comme
une **checklist de revue de code**, pas comme un label « 100 % safe ».

- Les **faux positifs** existent : si tu valides via un module séparé ou une fonction
  nommée, le plugin peut quand même lever une alerte (vérifie, puis ignore).
- Les **faux négatifs** existent aussi : une logique très indirecte peut passer sous le
  radar. Une alerte « propre » ne garantit pas l'absence totale de faille.
- L'analyse lie les remotes à leurs handlers par **nom** (heuristique), pas par référence
  d'instance — d'où la règle R7 qui peut signaler des remotes légitimes client‑à‑client.
