import "./vendor/turbo.js"
import { Application } from "./vendor/stimulus.js"
import FilterController from "./controllers/filter_controller.js"

Application.start().register("filter", FilterController)
