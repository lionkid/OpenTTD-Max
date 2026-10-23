/*
 * ScoreKeeper: the nine components of the company performance rating, computed the way economy.cpp
 * UpdateCompanyRatingAndValue does it on the first day of every quarter, so that every module can ask which
 * component is short and by how much. The game's own figure (AICompany.GetQuarterlyPerformanceRating) is
 * read for the last finished quarter and logged next to our estimate.
 *
 *   component     needed      points   source
 *   vehicles      120         100      vehicles whose profit last year was positive
 *   stations      80          100      facility parts (rail, truck, bus, airport, dock) of stations that loaded or
 *                                      unloaded in the last 20 rating periods (185 ticks each: 50 days)
 *   min profit    10,000      100      lowest profit last year among vehicles older than 730 days
 *   min income    50,000      50       lowest quarterly operating result of the last 12 quarters (revenue minus
 *                                      running costs, property and loan interest; construction does not count)
 *   max income    100,000     100      highest quarterly operating result of the last 12 quarters
 *   delivered     40,000      400      cargo units accepted at their destination in the last 4 quarters
 *   cargo types   8           50       distinct cargo types delivered in the last finished quarter
 *   money         10,000,000  50       cash (borrowed cash counts)
 *   loan          250,000     50       250,000 minus the loan
 *
 * Calendar of the ending year Y (game_creation.ending_year, default 2050): the high score is taken on
 * 1 January of Y+1 from the rating computed on 1 October of Y. That rating sees the vehicles' profit of the
 * calendar year Y-1 (profit_last_year is copied at the end of each year), the cash and loan of 1 October Y,
 * the cargo delivered from October Y-1 to September Y, and the cargo types of July-September Y. So:
 *   - a vehicle counts as profitable only if it earned money over the whole of Y-1: lines opened in Y add
 *     delivered cargo but no vehicle points; the fleet should be complete when Y-1 begins ("prepare" phase);
 *   - vehicles bought before October Y-2 are over two years old at the ranking and must earn 10,000 in
 *     Y-1, so weak old vehicles are replaced (a new vehicle has no age) or sold before then;
 *   - in Y itself ("harvest" phase) the loan is repaid and cash is kept for the money component.
 */

const SCORE_VEHICLES = 0;
const SCORE_STATIONS = 1;
const SCORE_MIN_PROFIT = 2;
const SCORE_MIN_INCOME = 3;
const SCORE_MAX_INCOME = 4;
const SCORE_DELIVERED = 5;
const SCORE_CARGO = 6;
const SCORE_MONEY = 7;
const SCORE_LOAN = 8;
const SCORE_COUNT = 9;

const PHASE_GROW = 0;      // more than a year before the decisive year
const PHASE_PREPARE = 1;   // the year Y-1: complete the fleet early, fix or drop weak vehicles
const PHASE_HARVEST = 2;   // the ending year Y: keep cash, repay the loan
const PHASE_OVER = 3;      // after the ranking

const SERVED_DAYS = 50;    // a station counts when it loaded or unloaded within this many days

class ScoreKeeper {
	needed = null;
	points = null;
	names = null;
	part = null;           // current value of each component (our estimate)
	got = null;            // points of each component (our estimate)
	total = 0;
	game_rating = -1;      // AICompany.GetQuarterlyPerformanceRating of the last finished quarter
	first_quarter = -1;    // date the company started (quarters before it have no statistics)
	cargo_quarter = null;  // cargo -> units our vehicles delivered this quarter (noted by the fleet)
	cargo_last = null;     // the same for the previous finished quarter
	phase = PHASE_GROW;
	min_quarter_income = 0;
	worst = -1;            // the old vehicle with the lowest profit last year

	constructor() {
		this.needed = [120, 80, 10000, 50000, 100000, 40000, 8, 10000000, 250000];
		this.points = [100, 100, 100, 50, 100, 400, 50, 50, 50];
		this.names = ["vehicles", "stations", "min profit", "min income", "max income", "delivered", "cargo types", "money", "loan"];
		this.part = array(SCORE_COUNT, 0);
		this.got = array(SCORE_COUNT, 0);
		this.cargo_quarter = {};
		this.cargo_last = {};
		this.first_quarter = Util.Today();
	}

	/* The fleet notes every delivery it sees (units of a cargo unloaded at a station that accepts it). */
	function NoteDelivery(cargo, units) {
		if (!(cargo in this.cargo_quarter)) this.cargo_quarter[cargo] <- 0;
		this.cargo_quarter[cargo] += units;
	}

	function Compute() {
		local p = array(SCORE_COUNT, 0);
		/* vehicles and the worst old one */
		local min_profit = 0, first = true, n = 0;
		this.worst = -1;
		foreach (v, _ in AIVehicleList()) {
			if (!AIVehicle.IsPrimaryVehicle(v)) continue;
			local profit = AIVehicle.GetProfitLastYear(v);
			if (profit > 0) n++;
			if (AIVehicle.GetAge(v) > 730) {
				if (first || profit < min_profit) { min_profit = profit; first = false; this.worst = v; }
			}
		}
		p[SCORE_VEHICLES] = n;
		p[SCORE_MIN_PROFIT] = max(0, min_profit);
		/* station facilities that are served */
		local parts = 0;
		foreach (sid, _ in AIStationList(AIStation.STATION_ANY)) {
			if (!::TY.network.IsServed(sid)) continue;
			foreach (t in [AIStation.STATION_TRAIN, AIStation.STATION_TRUCK_STOP, AIStation.STATION_BUS_STOP, AIStation.STATION_AIRPORT, AIStation.STATION_DOCK]) {
				if (AIStation.HasStationType(sid, t)) parts++;
			}
		}
		p[SCORE_STATIONS] = parts;
		/* operating result of the finished quarters */
		local quarters = this.FinishedQuarters();
		local lo = 0, hi = 0;
		for (local q = 1; q <= min(12, quarters); q++) {
			local net = this.QuarterResult(q);
			if (q == 1) { lo = net; hi = net; }
			else { lo = min(lo, net); hi = max(hi, net); }
		}
		this.min_quarter_income = lo;
		p[SCORE_MIN_INCOME] = max(0, lo);
		p[SCORE_MAX_INCOME] = max(0, hi);
		local delivered = 0;
		for (local q = 1; q <= min(4, quarters); q++) delivered += AICompany.GetQuarterlyCargoDelivered(AICompany.COMPANY_SELF, q);
		p[SCORE_DELIVERED] = delivered;
		p[SCORE_CARGO] = this.CargoTypes().len();
		p[SCORE_MONEY] = max(0, AICompany.GetBankBalance(AICompany.COMPANY_SELF));
		p[SCORE_LOAN] = this.needed[SCORE_LOAN] - AICompany.GetLoanAmount();
		this.part = p;
		this.total = 0;
		for (local i = 0; i < SCORE_COUNT; i++) {
			this.got[i] = Util.Clamp(p[i], 0, this.needed[i]) * this.points[i] / this.needed[i];
			this.total += this.got[i];
		}
		if (quarters >= 1) this.game_rating = AICompany.GetQuarterlyPerformanceRating(AICompany.COMPANY_SELF, 1);
		return this.total;
	}

	/* Revenue plus (negative) running costs, property and interest of quarter q (0 = the running one). */
	function QuarterResult(q) {
		return AICompany.GetQuarterlyIncome(AICompany.COMPANY_SELF, q) + AICompany.GetQuarterlyExpenses(AICompany.COMPANY_SELF, q);
	}

	/* Quarters with company statistics (the game keeps up to 24; a young company has fewer). */
	function FinishedQuarters() {
		local d0 = this.first_quarter, d1 = Util.Today();
		local q0 = AIDate.GetYear(d0) * 4 + Util.Quarter(d0), q1 = AIDate.GetYear(d1) * 4 + Util.Quarter(d1);
		return Util.Clamp(q1 - q0, 0, 24);
	}

	/* Points still missing on a component (0 when it is at target). */
	function Deficit(i) { return this.points[i] - this.got[i]; }

	/* Cargo types our vehicles deliver: a running line with a vehicle that has had time to complete a trip. */
	function CargoTypes() {
		local seen = {};
		foreach (l in ::TY.network.lines) {
			if (l.state != LINE_ACTIVE || (l.cargo in seen)) continue;
			foreach (v, _ in l.Vehicles()) {
				if (AIVehicle.GetAge(v) > 45 || AIVehicle.GetProfitThisYear(v) > 0) { seen[l.cargo] <- true; break; }
			}
		}
		local out = [];
		foreach (c, _ in seen) out.append(c);
		return out;
	}

	function CargoDelivered(c) { return Util.Contains(this.CargoTypes(), c); }

	/* Called on the first day of a new quarter. */
	function NewQuarter() {
		this.cargo_last = this.cargo_quarter;
		this.cargo_quarter = {};
		this.Compute();
		this.UpdatePhase();
		Log.Info("SCORE", "quarter " + (Util.Quarter() + 1) + "/" + Util.Year() + ": estimate " + this.total + "/1000" +
			(this.game_rating >= 0 ? ", game rating " + this.game_rating : "") + "; " + this.Summary());
		if (this.worst >= 0 && AIVehicle.IsValidVehicle(this.worst) && this.part[SCORE_MIN_PROFIT] < this.needed[SCORE_MIN_PROFIT]) {
			local line = ::TY.network.LineOfVehicle(this.worst);
			Log.Info("SCORE", "weakest old vehicle: " + AIVehicle.GetName(this.worst) + " (" + (line == null ? "no line" : line.Name() + ", state " + line.state) +
				"), age " + AIVehicle.GetAge(this.worst) + " d, profit last year " + Util.Money(AIVehicle.GetProfitLastYear(this.worst)) +
				", this year " + Util.Money(AIVehicle.GetProfitThisYear(this.worst)) + (this.worst in ::TY.fleet.to_sell ? ", being sold" : ""));
		}
	}

	function Summary() {
		local s = "";
		for (local i = 0; i < SCORE_COUNT; i++) {
			local v = this.part[i];
			local txt = (i == SCORE_MIN_PROFIT || i == SCORE_MIN_INCOME || i == SCORE_MAX_INCOME || i == SCORE_MONEY || i == SCORE_LOAN) ?
				Util.Money(v) : "" + v;
			s += (i > 0 ? ", " : "") + this.names[i] + " " + txt + " (" + this.got[i] + "/" + this.points[i] + ")";
		}
		return s;
	}

	function UpdatePhase() {
		local left = ::TY.game.YearsLeft();
		local was = this.phase;
		if (!::TY.levels.score_aware || ::TY.game.ending_year <= 0) this.phase = PHASE_GROW;
		else if (left < 0) this.phase = PHASE_OVER;
		else if (left == 0) this.phase = PHASE_HARVEST;
		else if (left == 1) this.phase = PHASE_PREPARE;
		else this.phase = PHASE_GROW;
		::TY.finance.harvest = this.phase == PHASE_HARVEST;
		/* the game's autorenew would hand the ranking a brand-new vehicle with no profit last year */
		AICompany.SetAutoRenewStatus(this.phase < PHASE_PREPARE || this.phase == PHASE_OVER);
		if (this.phase != was) {
			if (this.phase == PHASE_PREPARE) Log.Info("SCORE", "prepare phase: " + Util.Year() + " is the year the ranking measures vehicle profits; " +
				"new lines open early, weak old vehicles are replaced");
			if (this.phase == PHASE_HARVEST) Log.Info("SCORE", "harvest phase: ending year " + ::TY.game.ending_year +
				", the loan is repaid and cash is kept for the money component (ranking on 1 October)");
			if (this.phase == PHASE_OVER) Log.Info("SCORE", "the ranking has been taken; playing on");
		}
	}

	/*
	 * Money construction may still spend in the harvest phase: the cash above a target that climbs to ten
	 * million by October. Beyond that, buying a vehicle in the ending year adds delivered cargo but no
	 * vehicle points, so the purse closes once the target cannot be kept.
	 */
	function SpendingRoom() {
		local cash = AICompany.GetBankBalance(AICompany.COMPANY_SELF) - AICompany.GetLoanAmount();
		local month = AIDate.GetMonth(Util.Today());
		if (month >= 10) return max(0, cash - this.needed[SCORE_MONEY]);
		local target = this.needed[SCORE_MONEY] * month / 10;
		return max(0, cash - target);
	}
}
