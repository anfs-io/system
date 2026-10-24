import "./vendor/turbo.js"
import { Application } from "./vendor/stimulus.js"
import FilterController from "./controllers/filter_controller.js"
import SortController from "./controllers/sort_controller.js"

const application = Application.start()
application.register("filter", FilterController)
application.register("sort", SortController)
