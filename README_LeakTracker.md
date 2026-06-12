# Vitals · Memory — Plugin Roblox Studio

> Anciennement « Memory Leak & Connection Tracker ». Fait partie de la suite **Vitals** (Security · Memory · Performance).

Le 2ᵉ plugin de la suite « santé de jeu ». Il s'attaque au fléau n°2 de Roblox après
les exploiters : les **fuites mémoire**.

## Le problème

Les connexions (`:Connect`) jamais déconnectées et les instances jamais détruites font
gonfler la mémoire jusqu'au crash du serveur. La règle est connue, mais Roblox ne donne
**aucun** outil pour voir *quelle* connexion fuit ni *depuis quelle ligne*. On débogue à
l'aveugle.

Ce plugin a **deux moteurs**, dans deux onglets :

### 🔌 Onglet « Connexions » (analyse statique)

Scanne le code sans lancer le jeu et repère les connexions à risque :

| Code | Sévérité | Détecte |
|------|----------|---------|
| **L1** | Élevé / Moyen | Un `:Connect` dont le retour est **ignoré**, créé dans un scope qui **se répète** (boucle, ou handler comme `Heartbeat`/`Touched`/`Changed`). À chaque tour une connexion s'empile sans jamais être déconnectée. Élevé si le signal est à haute fréquence, Moyen sinon. |
| **L4** | Moyen | Un `Instance.new` dans un scope répétable **sans `:Destroy()`** dans le même bloc : les instances s'accumulent. |
| **L6** | Info | Le script crée ≥3 connexions au retour ignoré et **aucun Maid/Trove/Janitor** n'est détecté : pas de système de nettoyage. |

Une connexion est considérée **gérée** (donc non signalée) si son retour est stocké
(`local conn = ...`) ou ajouté à un Maid/Trove/Janitor (`maid:GiveTask(...)`). Les
connexions uniques au niveau racine d'un script (qui vivent toute la durée du script) ne
sont **pas** signalées — c'est une pratique normale.

Clique une alerte pour ouvrir le script à la ligne exacte.

### 📈 Onglet « Mémoire (live) »

Pendant un **playtest** (appuie sur **F5**), le plugin échantillonne la mémoire chaque
seconde et trace une mini-courbe (sparkline) pour chaque catégorie : **Total, Instances,
Signals, Lua Heap, Script**. Pour chacune, un verdict :

- **stable** ✅ — la mémoire oscille autour d'une valeur.
- **en hausse continue ⚠** — la catégorie ne fait que monter (pente positive sur la
  fenêtre) : symptôme classique d'une fuite. Si *Signals* monte sans cesse → connexions
  qui s'accumulent ; si *Instances* monte → objets jamais détruits.

Bouton **Reset le graphe** pour repartir d'une base propre (par ex. après le chargement
initial).

## Installation

1. Dans Studio, colle `MemoryLeakTracker.luau` dans un `Script` temporaire.
2. Clic droit → **Save as Local Plugin**.
3. Ouvre **Leak Tracker** (groupe *Securite* de la barre Plugins).
4. La 1ʳᵉ lecture de code demande la permission **Injection de script** — accepte (lecture
   seule, le plugin ne modifie jamais ton code).

Pour le suivi live : ouvre l'onglet **Mémoire**, lance le jeu en **F5** (Play Solo), joue
quelques minutes, et observe les courbes. Reviens en édition (Stop) quand tu as fini.

## Limites

- Analyse statique **heuristique** : à utiliser comme une checklist, pas comme une preuve.
  Une connexion gérée par un système maison non reconnu peut générer un faux positif.
- Le suivi live fonctionne en **Play Solo / Run** (même process). En *Team Test* (serveur
  séparé), le plugin ne voit pas la mémoire du serveur distant.
- Une hausse de mémoire peut être légitime (chargement de contenu) : juge la **tendance sur
  la durée**, pas un pic ponctuel.

## La suite « santé de jeu »

Ce plugin se combine avec **Remote Security Auditor** (sécurité des remotes). Ensemble ils
forment une petite suite cohérente : un audit avant chaque sortie pour un jeu sûr *et*
performant.
