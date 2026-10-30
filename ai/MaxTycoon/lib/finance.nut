/*
 * Loan and cash management. Construction asks Ensure() for money; the rest of the time the loan is repaid
 * down to what is needed, keeping a reserve for running costs and renewals.
 *
 * Two of the score components are money: GBP 10 million in the bank and no loan at all (economy.cpp
 * UpdateCompanyRatingAndValue). While the ending year is far away, money is better spent on anything that
 * raises the other components; in the ending year ("harvest"), the ScoreKeeper sets `harvest`, no new loan
 * is taken, the loan is paid off and cash is kept. Construction spending never touches the quarterly
 * operating result the score looks at (only revenue, running costs, property and interest do).
 */

class Finance {
	reserve_cache = 20000;
	trouble = false;          // set by ET_COMPANY_IN_TROUBLE until money recovers
	harvest = false;          // final years: keep cash, repay the loan, avoid losses
	quarter_spent = 0;        // construction and vehicle spending this quarter (for the income floor)

	function Cash() { return AICompany.GetBankBalance(AICompany.COMPANY_SELF); }
	function LoanRoom() { return this.harvest ? 0 : AICompany.GetMaxLoanAmount() - AICompany.GetLoanAmount(); }

	/* A few months of running costs, never less than the price of a cheap vehicle. */
	function UpdateReserve() {
		local list = AIVehicleList();
		list.Valuate(AIVehicle.GetRunningCost);
		local yearly = 0;
		foreach (v, cost in list) yearly += cost;
		this.reserve_cache = max(15000, yearly * ::TY.levels.reserve_months / 12);
	}

	function Reserve() { return this.reserve_cache; }

	/* Money that can be spent now without touching the reserve (including unused loan). */
	function Available() {
		local a = this.Cash() + this.LoanRoom() - this.Reserve();
		if (this.harvest) a = min(a, ::TY.score.SpendingRoom());
		return a;
	}

	function CanAfford(amount) { return !this.trouble && this.Available() >= amount; }

	/* Borrow so that `amount` can be spent while keeping the reserve. Returns true if the cash is there. */
	function Ensure(amount) {
		local want = amount + this.Reserve();
		local cash = this.Cash();
		if (cash >= want) return true;
		if (this.harvest) return cash >= amount;
		local interval = AICompany.GetLoanInterval();
		local loan = AICompany.GetLoanAmount();
		local target = loan + (want - cash);
		target = ((target + interval - 1) / interval) * interval;
		target = min(target, AICompany.GetMaxLoanAmount());
		if (target > loan) AICompany.SetLoanAmount(target);
		return this.Cash() >= amount;
	}

	/* Repay loan in whole intervals while the cash stays above the reserve. */
	function Repay() {
		local interval = AICompany.GetLoanInterval();
		local loan = AICompany.GetLoanAmount();
		if (loan <= 0) return;
		local spare = this.Cash() - this.Reserve() * (this.harvest ? 1 : 2);
		if (spare < interval) return;
		local pay = min(loan, (spare / interval) * interval);
		AICompany.SetLoanAmount(loan - pay);
	}

	function Status() {
		return "cash " + Util.Money(this.Cash()) + ", loan " + Util.Money(AICompany.GetLoanAmount()) + " of " +
			Util.Money(AICompany.GetMaxLoanAmount()) + ", reserve " + Util.Money(this.Reserve()) + (this.harvest ? ", harvest mode" : "");
	}
}
