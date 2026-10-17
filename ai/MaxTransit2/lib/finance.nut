/*
 * Loan and cash management for fast growth. A new route pays back its cost within a few years, which beats
 * the loan interest by far, so the whole loan stays drawn while there is something worth building. It is
 * repaid only with money no project can use: when the planner finds nothing affordable to build, or when
 * the cash in hand is far more than the next projects need.
 */

class Finance {
	reserve_cache = 15000;
	trouble = false;          // set by ET_COMPANY_IN_TROUBLE until money recovers
	idle = false;             // the planner found nothing to build last time
	next_need = 0;            // cost of the best project the planner is saving for

	function Cash() { return AICompany.GetBankBalance(AICompany.COMPANY_SELF); }
	function LoanRoom() { return AICompany.GetMaxLoanAmount() - AICompany.GetLoanAmount(); }

	/* Six weeks of running costs, never less than the price of a cheap vehicle. */
	function UpdateReserve() {
		local list = AIVehicleList();
		list.Valuate(AIVehicle.GetRunningCost);
		local yearly = 0;
		foreach (v, cost in list) yearly += cost;
		this.reserve_cache = max(12000, yearly / 8);
	}

	function Reserve() { return this.reserve_cache; }

	/* Money that can be spent now without touching the reserve (including unused loan). */
	function Available() { return this.Cash() + this.LoanRoom() - this.Reserve(); }

	function CanAfford(amount) { return !this.trouble && this.Available() >= amount; }

	/* Borrow so that `amount` can be spent while keeping the reserve. Returns true if the cash is there. */
	function Ensure(amount) {
		local want = amount + this.Reserve();
		local cash = this.Cash();
		if (cash >= want) return true;
		local interval = AICompany.GetLoanInterval();
		local loan = AICompany.GetLoanAmount();
		local target = loan + (want - cash);
		target = ((target + interval - 1) / interval) * interval;
		target = min(target, AICompany.GetMaxLoanAmount());
		if (target > loan) AICompany.SetLoanAmount(target);
		return this.Cash() >= amount;
	}

	/*
	 * Repay in whole loan intervals what neither the reserve nor the next project needs. While projects wait
	 * for money the loan stays drawn: a route earns far more than the interest.
	 */
	function Repay() {
		local interval = AICompany.GetLoanInterval();
		local loan = AICompany.GetLoanAmount();
		if (loan <= 0) return;
		local keep = this.Reserve() * 2 + (this.idle ? 0 : max(this.next_need, AICompany.GetMaxLoanAmount()));
		local spare = this.Cash() - keep;
		if (spare < interval) return;
		local pay = min(loan, (spare / interval) * interval);
		AICompany.SetLoanAmount(loan - pay);
	}

	function Status() {
		return "cash " + Util.Money(this.Cash()) + ", loan " + Util.Money(AICompany.GetLoanAmount()) + " of " +
			Util.Money(AICompany.GetMaxLoanAmount()) + ", reserve " + Util.Money(this.Reserve());
	}
}
