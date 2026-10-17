"""Writes the agent-expanded query fixture (FunesCore) and the Spanish queries (spike only).

The expansions are what a capable LLM agent would add to a request_memory call from the task
text alone: keywords for the kinds of personal context that could matter, and 1-3 of the 8
built-in category keys (which the MCP tool schema lists). They were written without consulting
the memories' wording; words that only make sense with knowledge of the vault were avoided.
"""
import json, sys
from pathlib import Path

CS, PP, SD, PC, PV, H, F, L = ("communication_style", "personal_preferences", "software_development",
                               "project_context", "privacy_preferences", "health", "finance", "legal")

# (query id, keywords, categories)
X = [
("q01", ["commit message conventions", "git", "commit style", "conventional commits", "version control", "tone", "changelog"], [SD, CS]),
("q02", ["diet", "dietary restrictions", "food allergies", "food preferences", "favourite cuisines", "cooking", "recipes", "meal planning", "nutrition", "grocery budget"], [PP, H]),
("q03", ["invoice", "overdue payment", "payment reminder", "late payment", "client", "treasurer", "sailing club", "email tone", "email signature", "billing terms"], [F, CS, PC]),
("q04", ["travel preferences", "train", "hotel", "accommodation", "seat preference", "travel budget", "payment card", "weekend trip"], [PP, F]),
("q05", ["coffee", "tea", "drink preferences", "caffeine", "milk", "dietary restrictions", "food allergies", "snacks"], [PP, H]),
("q06", ["Python", "project setup", "coding conventions", "linting", "type hints", "testing", "CSV", "bank statements", "parsing", "budgeting", "dependencies"], [SD, F, PC]),
("q07", ["code review", "pull request", "review style", "Nordwind", "client project", "coding standards", "TypeScript", "testing"], [SD, PC]),
("q08", ["running", "training plan", "fitness level", "injuries", "race goal", "marathon", "weekly mileage", "heart rate", "schedule"], [H, PP]),
("q09", ["calendar", "availability", "working hours", "meeting preferences", "calls", "time zone", "schedule", "client", "focus time"], [PP, CS, PC]),
("q10", ["allergies", "drug allergies", "medication", "medical history", "current medications", "health conditions", "side effects"], [H]),
("q11", ["income tax", "tax return", "accountant", "receipts", "invoices", "deductions", "business expenses", "freelance income", "tax deadlines"], [F, L]),
("q12", ["blog", "writing style", "tone", "Harbor app", "project details", "audience", "post length", "app development"], [CS, PC, SD]),
("q13", ["contract", "non-compete clause", "legal review", "lawyer", "contract terms", "freelance contracts", "negotiation"], [L]),
("q14", ["terms of service", "summary format", "privacy", "data sharing", "legal terms", "subscriptions", "auto-renewal"], [L, PV, CS]),
("q15", ["SwiftUI", "Swift style", "iOS", "macOS", "UI conventions", "accessibility", "architecture", "state management", "design"], [SD]),
("q16", ["Jordan", "gift ideas", "birthday", "partner", "interests", "hobbies", "likes and dislikes", "budget"], [PP]),
("q17", ["headache", "migraine", "eye strain", "screen time", "posture", "breaks", "sleep", "hydration", "stress", "medication"], [H]),
("q18", ["savings", "investments", "budget", "emergency fund", "income", "expenses", "financial goals", "retirement", "risk tolerance"], [F]),
("q19", ["privacy policy", "data collection", "analytics", "tracking", "App Store", "GDPR", "user data", "app details"], [L, PV, SD]),
("q20", ["mother", "parents", "family", "language", "tone", "travel plans", "visit"], [CS, PP]),
("q21", ["continuous integration", "CI", "GitHub Actions", "testing", "build", "open-source library", "project", "licence"], [SD, PC]),
("q22", ["hosting", "deployment", "server", "cloud provider", "infrastructure", "Docker", "booking app", "backend", "budget"], [SD, PC]),
("q23", ["rate", "pricing", "day rate", "availability", "proposal", "scope", "payment terms", "currency", "VAT", "contract"], [F, PC, CS]),
("q24", ["lease", "rental contract", "rent", "landlord", "tenancy", "notice period", "housing", "moving"], [L, F]),
("q25", ["meeting notes", "standup", "format", "action items", "team", "project", "summary"], [CS, PC]),
("q26", ["client data", "confidentiality", "NDA", "privacy", "AI tools", "data sharing", "database", "security"], [PV, L, PC]),
("q27", ["presentation", "slides", "talk", "conference", "presentation style", "slide design", "speaker notes"], [CS, PC]),
("q28", ["recipe", "quick dinner", "diet", "dietary restrictions", "allergies", "cooking equipment", "cuisine", "measurement units"], [PP, H]),
("q29", ["boating", "sailing", "packing list", "sun protection", "weather", "gear", "water activities"], [PP, H]),
("q30", ["kitchen renovation", "remodel", "budget", "savings", "financing", "loan", "home improvement", "costs"], [F, PC]),
]

ES = {
"q01": "Escribí un mensaje de commit para mi último cambio",
"q02": "Planificá las cenas de la semana para mí",
"q03": "Redactá un correo para recordarle al tesorero del club de vela que la factura del mes pasado está vencida",
"q04": "Reservá pasajes de tren y alojamiento para un fin de semana en Oporto",
"q05": "¿Qué debería pedir en un café esta tarde?",
"q06": "Armá un proyecto nuevo en Python que procese los extractos bancarios exportados",
"q07": "Revisá este pull request del servicio de despacho de Nordwind",
"q08": "Sugerime un plan de carrera para las próximas cuatro semanas",
"q09": "Buscá un horario la semana que viene para una llamada de presentación con un posible cliente",
"q10": "El médico quiere recetarme antibióticos. ¿Hay algo que debería saber?",
"q11": "Ayudame a juntar los papeles para la declaración de impuestos de este año",
"q12": "Ayudame a escribir una entrada de blog sobre cómo construí la app Harbor",
"q13": "Un cliente me mandó un contrato con una cláusula de no competencia de 12 meses. ¿Lo firmo?",
"q14": "Resumí los términos y condiciones de este servicio nuevo",
"q15": "Hacé una pantalla de ajustes para mi app en SwiftUI",
"q16": "¿Qué le regalo a Jordan para su cumpleaños?",
"q17": "Me duele la cabeza después de un día largo frente a la computadora. ¿Algún consejo?",
"q18": "¿Cuánto debería destinar a ahorros e inversiones este mes?",
"q19": "Escribí la política de privacidad de mi app para iOS",
"q20": "Ayudame a escribirle un mensaje a mi mamá sobre mi próxima visita",
"q21": "Configurá compilaciones y pruebas automáticas para mi biblioteca de código abierto",
"q22": "¿Dónde debería desplegar el servidor de la app de reservas?",
"q23": "Prepará un presupuesto para un trabajo freelance de tres semanas",
"q24": "El dueño del departamento preguntó si nos vamos a quedar cuando termine el contrato",
"q25": "Pasá en limpio las notas de la reunión diaria de hoy",
"q26": "¿Puedo pegar el esquema de la base de datos del cliente en ChatGPT para depurar una consulta?",
"q27": "Prepará las diapositivas para mi charla en la conferencia de Oporto",
"q28": "Buscá una receta que pueda cocinar esta noche en media hora",
"q29": "¿Qué llevo para pasar un día en el agua?",
"q30": "¿Cuánto podemos gastar en reformar la cocina y cómo lo vamos a pagar?",
}

fixtures, spike = Path(sys.argv[1]), Path(sys.argv[2])
queries = json.loads((fixtures / "queries-30.json").read_text())["queries"]
assert [q["id"] for q in queries] == [x[0] for x in X] == list(ES)
cats = {CS, PP, SD, PC, PV, H, F, L}
for _, kw, c in X:
    assert 5 <= len(kw) <= 15 and 1 <= len(c) <= 3 and set(c) <= cats
expanded = {
    "format": "funes.fixture.queries-expanded.v1",
    "note": ("The 30 queries as an agent might send them to request_memory: the task plus 5-15 keywords and "
             "1-3 category keys, written from the task text alone without looking at the memories (Spike 2b)."),
    "queries": [{"id": q["id"], "query": q["query"], "keywords": kw, "categories": c, "relevant": q["relevant"]}
                for q, (_, kw, c) in zip(queries, X)],
}
(fixtures / "queries-30-expanded.json").write_text(json.dumps(expanded, ensure_ascii=False, indent=2) + "\n")
es = {"note": "Spanish (Rioplatense) translations of queries-30, for the multilingual check in Spike 2b.",
      "queries": [{"id": q["id"], "query": ES[q["id"]], "relevant": q["relevant"]} for q in queries]}
(spike / "queries-30-es.json").write_text(json.dumps(es, ensure_ascii=False, indent=2) + "\n")
print("ok")
