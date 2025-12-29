import SwiftUI
import SwiftData

@main
struct FinApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Expense.self,
            Category.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Seed default categories if needed
            let context = container.mainContext
            let descriptor = FetchDescriptor<Category>()
            let existingCategories = try context.fetch(descriptor)

            if existingCategories.isEmpty {
                seedCategories(context: context)
            }

            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            UnifiedAddView()
        }
        .modelContainer(sharedModelContainer)
    }
}

private func seedCategories(context: ModelContext) {
    let defaults: [(String, String, String, String)] = [
        ("Vivienda", "🏠", "#4CAF50", "alquiler,expensas,luz,gas,agua,edenor,edesur,metrogas,aysa,aguas cordobesas,epec,electricidad"),
        ("Comida", "🛒", "#FF9800", "supermercado,almacen,verduleria,carrefour,coto,dia,jumbo,disco,grido,helado,carniceria,pollo,cerdo,milanesa"),
        ("Restaurantes", "🍽️", "#FFC107", "restaurant,bar,cafe,pizzeria,delivery,rappi,pedidosya,havanna,freddo,starbucks,antares,cerveza,brewery,cerveceria"),
        ("Transporte", "🚌", "#2196F3", "nafta,combustible,sube,uber,taxi,cabify,ypf,shell,axion,pasajes"),
        ("Entretenimiento", "🎬", "#9C27B0", "cine,teatro,streaming,spotify,netflix,disney,hbo,amazon,steam"),
        ("Servicios", "📱", "#607D8B", "telefono,internet,celular,personal,claro,movistar,fibertel,telecentro,naranja,visa,mastercard,tarjeta,resumen,monotributo,afip,impuesto,santander,banco,transferencia,western union,remesa,envio,giro,multa,infraccion,municipalidad,brubank,pagofacil,pagomiscuentas"),
        ("Salud", "💊", "#E91E63", "farmacia,medico,hospital,osde,swiss,prepaga,prevencion"),
        ("Ropa", "👕", "#00BCD4", "ropa,zapatillas,shopping,zara,nike,adidas,corbata,chaleco,camisa,pantalon,zapato,traje"),
        ("Otros", "📦", "#795548", ""),
    ]

    for (name, emoji, color, keywords) in defaults {
        let category = Category(name: name, emoji: emoji, colorHex: color, keywords: keywords)
        context.insert(category)
    }
}
