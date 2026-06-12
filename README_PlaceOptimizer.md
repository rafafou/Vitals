# Vitals · Performance — Plugin Roblox Studio

> Anciennement « Place Optimizer ». Fait partie de la suite **Vitals** (Security · Memory · Performance).

Le 3ᵉ plugin de la suite « santé de jeu ». Il répond à une envie universelle : **un jeu
qui charge vite et ne rame pas**.

## Le problème

Rien dans Studio ne te dit ce qui **alourdit** ton place : code mort, unions CSG lentes,
parts fantômes oubliées, milliers de parts sans streaming… On le découvre quand les
joueurs se plaignent du temps de chargement.

Ce plugin scanne ton jeu, calcule un **Score d'optimisation /100**, et liste exactement
quoi alléger. Clique une alerte → ça **sélectionne les objets concernés** dans l'Explorer
pour que tu agisses tout de suite. Il ne modifie jamais ton jeu (il sélectionne, c'est
tout).

## Les 9 règles

| Code | Sévérité | Détecte | Gain |
|------|----------|---------|------|
| **O1** | Moyen | ModuleScripts jamais require()/cités — code mort. | Poids + chargement |
| **O2** | Faible | Scripts au code identique (copier-coller). | Maintenance + poids |
| **O3** | Faible | Scripts vides ou désactivés. | Poids mort |
| **O4** | Moyen* | UnionOperations (CSG) — lourdes et lentes à charger. | Temps de chargement |
| **O5** | Info | Parts fantômes : transparentes + sans collision + sans enfant. | Nettoyage |
| **O6** | Info | ≥50 parts non ancrées (coût physique inutile sur du décor). | CPU serveur |
| **O7** | Moyen | ≥1000 parts **et** StreamingEnabled désactivé. | **Gros gain de chargement** |
| **O8** | Info | ≥200 décals / textures / images. | Mémoire graphique |
| **O9** | Faible | MeshParts en CollisionFidelity = Precise (collision coûteuse). | Performance + chargement |

\* O4 passe en *Moyen* au-delà de 40 unions, *Faible* en dessous.

Le **score** part de 100 et retire des points par alerte selon la sévérité (élevé −15,
moyen −8, faible −3, info −1). Verdict : *Léger* (≥85), *Correct* (≥60), *Lourd* (≥35),
*Très lourd* (<35).

## Installation

1. Colle `PlaceOptimizer.luau` dans un `Script`, clic droit → **Save as Local Plugin**.
2. Ouvre **Place Optimizer** (groupe *Securite* de la barre Plugins).
3. Clique **Analyser le poids du jeu**. Accepte la permission « Injection de script »
   (nécessaire pour lire le code et repérer le code mort).
4. Parcours les alertes, clique **Sélectionner les objets** pour les voir dans l'Explorer,
   puis supprime / corrige.

## Limites

- Analyse **heuristique** : une part « fantôme » peut être une hitbox invisible
  volontaire, un module « inutilisé » peut être chargé dynamiquement par nom. **Vérifie
  avant de supprimer.**
- La sélection est **plafonnée à 200 objets** par clic pour rester fluide (le compteur
  affiche le total réel).
- Sur les très gros jeux, le scan des parts est limité à 12 000 pour éviter tout gel.
- Il ne lit pas la taille réelle des textures (Roblox ne l'expose pas au plugin) : O8 se
  base sur le nombre d'assets image.

## La suite « santé de jeu »

Avec **Remote Security Auditor** (sécurité) et **Memory Leak & Connection Tracker**
(fuites), tu as maintenant les trois piliers : un jeu **sûr**, **stable** et **léger**.
Un passage des trois avant chaque sortie.
